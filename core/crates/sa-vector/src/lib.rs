//! Vectors for search by meaning (plan §6.7, D5): storage format and an exact scan.
//!
//! Pure functions and one in-memory index. No files, no database, no model, so each rule is tested by itself.
//!
//! * A vector is **L2-normalised** and stored as **f16** (2 bytes per number, little endian). The model itself must
//!   run in bf16/f32 (f16 breaks it); storing its *finished, normalised output* in f16 was measured safe (cosine
//!   error about 6e-5, `docs/research/phase3-model-spikes.md` §4.3).
//! * Search is an **exact scan**: on real vectors 20,000 × 768 take 173 µs, so 250,000 take about 2 ms, far inside
//!   the 150 ms budget. No graph index is built (D5); this crate is where one would go if a library outgrew that.
//! * One asset may have several rows (a video has one per keyframe); its score is its best row.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::assert_is_empty))]
// Converting between float widths and integer widths is the whole job of this file; every cast is bounded by the
// format (a 16-bit pattern, a 10-bit mantissa) and covered by the exhaustive round-trip test below.
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_possible_wrap,
    clippy::cast_precision_loss
)]

use rayon::prelude::*;
use std::cmp::Ordering;
use std::collections::BinaryHeap;

/// IEEE 754 half precision from single precision, rounding to nearest even. Overflow becomes infinity.
#[must_use]
pub fn f32_to_f16(x: f32) -> u16 {
    let bits = x.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let mant = bits & 0x007F_FFFF;
    if exp == 0xFF {
        // Infinity stays infinity; any NaN becomes one quiet NaN.
        return sign | 0x7C00 | if mant != 0 { 0x0200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1F {
        return sign | 0x7C00;
    }
    if e <= 0 {
        // Subnormal in half precision, or zero.
        if e < -10 {
            return sign;
        }
        let m = mant | 0x0080_0000;
        let shift = (14 - e) as u32;
        let mut half = m >> shift;
        let rest = m & ((1 << shift) - 1);
        let middle = 1 << (shift - 1);
        if rest > middle || (rest == middle && half & 1 == 1) {
            half += 1;
        }
        return sign | half as u16;
    }
    let mut half = ((e as u32) << 10) | (mant >> 13);
    let rest = mant & 0x1FFF;
    if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) {
        // A carry out of the mantissa correctly bumps the exponent (and may reach infinity).
        half += 1;
    }
    sign | half as u16
}

/// Single precision from half precision (exact).
#[must_use]
pub fn f16_to_f32(h: u16) -> f32 {
    let sign = (u32::from(h) & 0x8000) << 16;
    let exp = u32::from(h >> 10) & 0x1F;
    let mant = u32::from(h) & 0x03FF;
    let bits = match (exp, mant) {
        (0, 0) => sign,
        (0, m) => {
            // Subnormal: normalise it.
            let shift = m.leading_zeros() - 21;
            let m = (m << shift) & 0x03FF;
            sign | ((127 - 15 - shift + 1) << 23) | (m << 13)
        }
        (0x1F, 0) => sign | 0x7F80_0000,
        (0x1F, m) => sign | 0x7FC0_0000 | (m << 13),
        (e, m) => sign | ((e + 127 - 15) << 23) | (m << 13),
    };
    f32::from_bits(bits)
}

/// Scales `v` to length 1. Returns `false`, leaving `v` untouched, when that is impossible: an empty or all-zero
/// vector, or one containing NaN or infinity (a model that failed must never be stored as if it had answered).
pub fn normalise(v: &mut [f32]) -> bool {
    if v.is_empty() || v.iter().any(|x| !x.is_finite()) {
        return false;
    }
    let norm = v.iter().map(|x| f64::from(*x) * f64::from(*x)).sum::<f64>().sqrt();
    if norm < 1e-12 {
        return false;
    }
    for x in v.iter_mut() {
        *x = (f64::from(*x) / norm) as f32;
    }
    true
}

/// The stored form: f16, little endian, two bytes per number.
#[must_use]
pub fn encode_f16(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| f32_to_f16(*x).to_le_bytes()).collect()
}

/// The numbers in a stored vector, or `None` if the bytes are not a whole number of f16 values.
#[must_use]
pub fn decode_f16(bytes: &[u8]) -> Option<Vec<f32>> {
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    Some(bytes.as_chunks::<2>().0.iter().map(|c| f16_to_f32(u16::from_le_bytes(*c))).collect())
}

/// One answer: an asset and how close it is to the question (cosine similarity, -1 to 1).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hit {
    pub asset_id: i64,
    pub score: f32,
}

/// An answer with the shape of the scores behind it. A question the library cannot answer scores everything alike, so
/// its best match barely stands out of the crowd; a question about something in the library has a best match well above
/// the rest. `mean` and `std` describe every allowed asset's score, not only the ones returned.
#[derive(Debug, Clone, PartialEq)]
pub struct Answer {
    pub hits: Vec<Hit>,
    pub mean: f32,
    pub std: f32,
    /// How many assets the mean and spread are taken over.
    pub count: u64,
}

impl Answer {
    /// Nothing answered.
    #[must_use]
    pub fn empty() -> Self {
        Self { hits: Vec::new(), mean: 0.0, std: 0.0, count: 0 }
    }

    /// One answer from two indexes that hold *different* assets (the same question asked of both): the `k` best hits of
    /// either, and the mean and spread over all the assets of both.
    #[must_use]
    pub fn merge(self, other: Self, k: usize) -> Self {
        if other.count == 0 {
            return self;
        }
        if self.count == 0 {
            return other;
        }
        let mut hits = self.hits;
        hits.extend(other.hits);
        hits.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.asset_id.cmp(&b.asset_id)));
        hits.truncate(k);
        let (na, nb) = (self.count as f64, other.count as f64);
        let n = na + nb;
        let second = |mean: f32, std: f32| f64::from(std) * f64::from(std) + f64::from(mean) * f64::from(mean);
        let mean = (na * f64::from(self.mean) + nb * f64::from(other.mean)) / n;
        let moment = (na * second(self.mean, self.std) + nb * second(other.mean, other.std)) / n;
        let std = (moment - mean * mean).max(0.0).sqrt();
        Self { hits, mean: mean as f32, std: std as f32, count: self.count + other.count }
    }

    /// How many standard deviations a score lies above the library's average score for this question.
    #[must_use]
    pub fn z(&self, score: f32) -> f32 {
        if self.std > 1e-9 { (score - self.mean) / self.std } else { 0.0 }
    }
}

/// All vectors of one model configuration, held in memory as f16.
#[derive(Debug, Clone)]
pub struct Index {
    dims: usize,
    /// Asset of each row. Rows of one asset must be next to each other.
    ids: Vec<i64>,
    data: Vec<u16>,
}

impl Index {
    #[must_use]
    pub fn new(dims: usize) -> Self {
        Self { dims, ids: Vec::new(), data: Vec::new() }
    }

    #[must_use]
    pub fn dims(&self) -> usize {
        self.dims
    }

    /// Number of rows (a video counts once per keyframe).
    #[must_use]
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// Memory held by the vectors and ids.
    #[must_use]
    pub fn bytes(&self) -> usize {
        self.data.len() * 2 + self.ids.len() * 8
    }

    /// Adds a stored vector. Returns `false` (and adds nothing) when its length is not `dims` numbers.
    pub fn push(&mut self, asset_id: i64, stored: &[u8]) -> bool {
        if stored.len() != self.dims * 2 {
            return false;
        }
        self.ids.push(asset_id);
        self.data.extend(stored.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)));
        true
    }

    /// The `k` assets closest to `query` (which should be normalised), best first. `allow` limits which assets may be
    /// answered (the filters in effect); `None` allows all. Returns nothing if `query` has the wrong length.
    #[must_use]
    pub fn top_k(&self, query: &[f32], k: usize, allow: Option<&(dyn Fn(i64) -> bool + Sync)>) -> Vec<Hit> {
        self.answer(query, k, allow).hits
    }

    /// Like [`Index::top_k`], with the mean and spread of all the scores (see [`Answer`]).
    #[must_use]
    pub fn answer(&self, query: &[f32], k: usize, allow: Option<&(dyn Fn(i64) -> bool + Sync)>) -> Answer {
        let empty = Answer::empty();
        if query.len() != self.dims || k == 0 || self.is_empty() {
            return empty;
        }
        let dims = self.dims;
        let scores: Vec<f32> = self
            .data
            .par_chunks_exact(dims)
            .map(|row| row.iter().zip(query).map(|(h, q)| f16_to_f32(*h) * q).sum())
            .collect();
        // Best row per asset (rows of one asset are adjacent), then the k best assets.
        let mut heap: BinaryHeap<Ranked> = BinaryHeap::with_capacity(k + 1);
        let (mut count, mut sum, mut sum_sq) = (0_u64, 0.0_f64, 0.0_f64);
        let mut i = 0;
        while i < self.ids.len() {
            let id = self.ids[i];
            let mut best = scores[i];
            let mut j = i + 1;
            while j < self.ids.len() && self.ids[j] == id {
                best = best.max(scores[j]);
                j += 1;
            }
            i = j;
            if !best.is_finite() || allow.is_some_and(|f| !f(id)) {
                continue;
            }
            count += 1;
            sum += f64::from(best);
            sum_sq += f64::from(best) * f64::from(best);
            heap.push(Ranked(Hit { asset_id: id, score: best }));
            if heap.len() > k {
                heap.pop();
            }
        }
        let mut hits: Vec<Hit> = heap.into_iter().map(|r| r.0).collect();
        hits.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.asset_id.cmp(&b.asset_id)));
        if count == 0 {
            return empty;
        }
        let mean = sum / count as f64;
        let variance = (sum_sq / count as f64 - mean * mean).max(0.0);
        Answer { hits, mean: mean as f32, std: variance.sqrt() as f32, count }
    }
}

/// Heap entry ordered so the *worst* kept hit is on top (a min-heap on score).
#[derive(Debug, Clone, Copy)]
struct Ranked(Hit);

impl PartialEq for Ranked {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Ranked {}
impl PartialOrd for Ranked {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Ranked {
    fn cmp(&self, other: &Self) -> Ordering {
        // Worst = lowest score, and among equal scores the highest id, so the lower ids are the ones kept.
        other.0.score.total_cmp(&self.0.score).then(self.0.asset_id.cmp(&other.0.asset_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_f16_value_survives_a_round_trip() {
        for h in 0..=u16::MAX {
            let x = f16_to_f32(h);
            if x.is_nan() {
                assert!(f16_to_f32(f32_to_f16(x)).is_nan());
            } else {
                assert_eq!(f32_to_f16(x), h, "pattern {h:#06x} = {x}");
            }
        }
    }

    #[test]
    fn known_conversions_match_ieee() {
        assert_eq!(f32_to_f16(1.0), 0x3C00);
        assert_eq!(f32_to_f16(-2.0), 0xC000);
        assert_eq!(f32_to_f16(0.5), 0x3800);
        assert_eq!(f32_to_f16(65504.0), 0x7BFF);
        assert_eq!(f32_to_f16(70000.0), 0x7C00, "overflow is infinity");
        assert_eq!(f32_to_f16(1e-9), 0x0000, "underflow is zero");
        assert_eq!(f32_to_f16(5.960_464_5e-8), 0x0001, "smallest subnormal");
        assert!((f16_to_f32(0x3555) - 0.333_251_95).abs() < 1e-7);
    }

    #[test]
    fn storing_a_normalised_vector_in_f16_keeps_cosine_within_a_tenth_of_a_percent() {
        let mut a: Vec<f32> = (0..768).map(|i| ((i * 37 % 101) as f32 - 50.0) / 13.0).collect();
        let mut b: Vec<f32> = (0..768).map(|i| ((i * 53 % 97) as f32 - 48.0) / 11.0).collect();
        assert!(normalise(&mut a) && normalise(&mut b));
        let exact: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        let (sa, sb) = (decode_f16(&encode_f16(&a)).unwrap(), decode_f16(&encode_f16(&b)).unwrap());
        let stored: f32 = sa.iter().zip(&sb).map(|(x, y)| x * y).sum();
        assert!((exact - stored).abs() < 1e-3, "{exact} against {stored}");
    }

    #[test]
    fn normalise_refuses_vectors_that_are_not_an_answer() {
        assert!(!normalise(&mut []));
        assert!(!normalise(&mut [0.0, 0.0]));
        let mut with_nan = [1.0, f32::NAN];
        assert!(!normalise(&mut with_nan));
        assert_eq!(with_nan[0], 1.0, "left untouched");
        assert!(!normalise(&mut [f32::INFINITY, 1.0]));
        let mut v = [3.0, 4.0];
        assert!(normalise(&mut v));
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
    }

    #[test]
    fn decode_rejects_half_a_number() {
        assert!(decode_f16(&[1, 2, 3]).is_none());
        assert_eq!(decode_f16(&[]).unwrap().len(), 0);
    }

    fn unit(dims: usize, axis: usize) -> Vec<f32> {
        let mut v = vec![0.0; dims];
        v[axis] = 1.0;
        v
    }

    fn index_of(rows: &[(i64, Vec<f32>)]) -> Index {
        let mut ix = Index::new(4);
        for (id, v) in rows {
            assert!(ix.push(*id, &encode_f16(v)));
        }
        ix
    }

    #[test]
    fn the_closest_assets_come_first() {
        let ix = index_of(&[(1, unit(4, 0)), (2, vec![0.8, 0.6, 0.0, 0.0]), (3, unit(4, 1)), (4, vec![-1.0, 0.0, 0.0, 0.0])]);
        let hits = ix.top_k(&unit(4, 0), 3, None);
        let ids: Vec<i64> = hits.iter().map(|h| h.asset_id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
        assert!((hits[0].score - 1.0).abs() < 1e-3 && (hits[1].score - 0.8).abs() < 1e-3);
    }

    #[test]
    fn a_video_scores_as_its_best_keyframe() {
        // Asset 7 has three keyframes; only the last one looks like the question.
        let ix = index_of(&[(5, vec![0.9, 0.1, 0.0, 0.0]), (7, unit(4, 2)), (7, unit(4, 3)), (7, unit(4, 0))]);
        let hits = ix.top_k(&unit(4, 0), 5, None);
        assert_eq!(hits.len(), 2, "one hit per asset, not per row");
        assert_eq!(hits[0].asset_id, 7);
    }

    #[test]
    fn filters_limit_who_can_be_answered() {
        let ix = index_of(&[(1, unit(4, 0)), (2, vec![0.8, 0.6, 0.0, 0.0])]);
        let only_two = |id: i64| id == 2;
        let hits = ix.top_k(&unit(4, 0), 5, Some(&only_two));
        assert_eq!(hits.iter().map(|h| h.asset_id).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn a_wrong_sized_question_or_row_is_refused() {
        let mut ix = Index::new(4);
        assert!(!ix.push(1, &encode_f16(&[1.0, 0.0])), "row of 2 numbers into 4 dims");
        assert!(ix.is_empty());
        assert!(index_of(&[(1, unit(4, 0))]).top_k(&[1.0, 0.0], 3, None).is_empty());
        assert!(index_of(&[(1, unit(4, 0))]).top_k(&unit(4, 0), 0, None).is_empty());
    }

    #[test]
    fn a_question_about_something_stands_out_and_a_question_about_nothing_does_not() {
        // Ten assets, each on its own axis of 16: a question on axis 3 is answered by asset 3 alone.
        let mut ix = Index::new(16);
        for id in 0..10_i64 {
            assert!(ix.push(id, &encode_f16(&unit(16, id as usize))));
        }
        let sharp = ix.answer(&unit(16, 3), 3, None);
        assert_eq!(sharp.hits[0].asset_id, 3);
        assert!(sharp.z(sharp.hits[0].score) > 2.5, "a clear answer is well above the crowd: {}", sharp.z(sharp.hits[0].score));
        // A question that every asset answers equally well has no spread, so nothing stands out.
        let flat_query = vec![0.25_f32; 16];
        let flat = ix.answer(&flat_query, 3, None);
        assert!(flat.z(flat.hits[0].score).abs() < 1e-3, "no spread, no standing out: {}", flat.z(flat.hits[0].score));
    }

    #[test]
    fn two_answers_merge_as_if_one_index_held_every_asset() {
        let rows_a = [(1, unit(4, 0)), (2, vec![0.8, 0.6, 0.0, 0.0]), (3, unit(4, 1))];
        let rows_b = [(4, vec![0.6, 0.8, 0.0, 0.0]), (5, unit(4, 2))];
        let all: Vec<(i64, Vec<f32>)> = rows_a.iter().chain(rows_b.iter()).cloned().collect();
        let q = unit(4, 0);
        let merged = index_of(&rows_a).answer(&q, 3, None).merge(index_of(&rows_b).answer(&q, 3, None), 3);
        let whole = index_of(&all).answer(&q, 3, None);
        assert_eq!(merged.hits.iter().map(|h| h.asset_id).collect::<Vec<_>>(), vec![1, 2, 4]);
        assert_eq!(merged.hits, whole.hits);
        assert_eq!(merged.count, 5);
        assert!((merged.mean - whole.mean).abs() < 1e-5 && (merged.std - whole.std).abs() < 1e-5);
        assert_eq!(Answer::empty().merge(whole.clone(), 3), whole, "an empty side changes nothing");
    }

    #[test]
    fn ties_break_by_asset_id_so_results_are_stable() {
        let ix = index_of(&[(9, unit(4, 0)), (3, unit(4, 0)), (6, unit(4, 0))]);
        let ids: Vec<i64> = ix.top_k(&unit(4, 0), 2, None).iter().map(|h| h.asset_id).collect();
        assert_eq!(ids, vec![3, 6]);
    }
}
