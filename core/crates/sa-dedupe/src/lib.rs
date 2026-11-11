//! Near-duplicate matching (plan A2): which pictures and videos look like the same shot.
//!
//! Pure functions over perceptual hashes. No files, no database, no clock, so every rule here is tested by itself.
//!
//! * A picture is described by two 64-bit hashes: a difference hash (`d`, gradients) and a DCT hash (`p`, low
//!   frequencies). Two pictures match when both are close in Hamming distance. Using both removes most false
//!   matches that either one makes alone.
//! * A video is described by the same pair for a few keyframes taken at fixed fractions of its duration, and also
//!   has to be about as long as the other.
//! * Candidates come from multi-index hashing, so a large library is not compared pair by pair.
//! * Matches are grouped around an anchor, so a chain of look-alikes (A like B, B like C, A not like C) never
//!   becomes one big group.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::assert_is_empty))]

use rayon::prelude::*;

/// The two hashes of one sampled picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hash {
    /// Difference hash: 64 left-versus-right brightness comparisons on a 9 by 8 grid.
    pub d: u64,
    /// DCT hash: 63 low-frequency coefficients of a 32 by 32 grid against their median.
    pub p: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Image,
    Video,
}

/// One file to compare.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub id: i64,
    pub kind: Kind,
    pub duration_ms: Option<i64>,
    /// Files with the same full-content hash share this key. A group made only of such files is an exact group,
    /// shown elsewhere, not a near-duplicate group.
    pub exact_key: Option<u64>,
    /// One hash for a picture; one per sampled keyframe, in time order, for a video.
    pub slots: Vec<Hash>,
}

/// How close two files must be to match. Distances are counted in differing bits out of 64.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    /// Largest average DCT-hash distance.
    pub max_p: u32,
    /// Largest average difference-hash distance.
    pub max_d: u32,
}

impl Default for Config {
    fn default() -> Self {
        // Chosen on the labeled set of 200 real photographs in `docs/ROADMAP.md` (Phase 2): no false pair at these
        // limits, and the first false pairs appear two bits looser. Precision first.
        Self { max_p: 10, max_d: 12 }
    }
}

/// A file in a near-duplicate group and how close it is to the group's anchor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Member {
    pub id: i64,
    /// 0 to 100. 100 means the hashes are identical.
    pub similarity: u8,
}

/// Files that look like the same shot. The anchor comes first, with similarity 100.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub members: Vec<Member>,
}

/// Groups smaller than this library size are compared pair by pair; the index is not worth building.
const BRUTE_FORCE_BELOW: usize = 1_500;
/// Video keyframes may differ by this much more than the average and still match (one flash or fade).
const VIDEO_SLOT_SLACK: u32 = 4;

/// A hash with almost all bits equal comes from a plain picture: a black frame, a solid colour, a blank page, or a
/// smooth gradient (whose difference hash is all 0 or all 1). Such pictures all look alike to the hashes, so they
/// are never matched. Exact copies of them are still found by their content.
#[must_use]
pub fn is_informative(h: Hash) -> bool {
    (14..=49).contains(&h.p.count_ones()) && (4..=60).contains(&h.d.count_ones())
}

fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

/// Similarity from the two average distances: 100 when both are 0, falling by 100/64 for every differing bit.
fn similarity(sum_p: u32, sum_d: u32, samples: u32) -> u8 {
    let avg = f64::from(sum_p + sum_d) / f64::from(samples.max(1));
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let s = (100.0 - avg * 100.0 / 64.0).round().clamp(0.0, 100.0) as u8;
    s
}

fn duration_close(a: Option<i64>, b: Option<i64>) -> bool {
    let (Some(a), Some(b)) = (a, b) else { return false };
    let longer = a.max(b);
    (a - b).abs() <= (longer / 50).max(1_000)
}

/// Whether two files match, and how well.
#[must_use]
pub fn compare(first: &Item, second: &Item, cfg: Config) -> Option<u8> {
    if first.kind != second.kind || first.id == second.id {
        return None;
    }
    let samples = first.slots.len().min(second.slots.len());
    if samples == 0 || first.slots.iter().chain(&second.slots).any(|h| !is_informative(*h)) {
        return None;
    }
    if first.kind == Kind::Video && !duration_close(first.duration_ms, second.duration_ms) {
        return None;
    }
    let (mut sum_p, mut sum_d) = (0u32, 0u32);
    for (x, y) in first.slots.iter().zip(&second.slots).take(samples) {
        let (dct, diff) = (hamming(x.p, y.p), hamming(x.d, y.d));
        if first.kind == Kind::Video && dct > cfg.max_p + VIDEO_SLOT_SLACK {
            return None;
        }
        sum_p += dct;
        sum_d += diff;
    }
    let count = u32::try_from(samples).unwrap_or(1);
    (sum_p <= cfg.max_p * count && sum_d <= cfg.max_d * count).then(|| similarity(sum_p, sum_d, count))
}

/// Chunk layout for multi-index hashing: `m` chunks that together cover 64 bits.
fn chunks(m: u32) -> Vec<(u32, u32)> {
    let base = 64 / m;
    let extra = 64 % m;
    let mut out = Vec::with_capacity(m as usize);
    let mut shift = 0;
    for i in 0..m {
        let width = base + u32::from(i < extra);
        out.push((shift, width));
        shift += width;
    }
    out
}

fn chunk_key(p: u64, shift: u32, width: u32) -> usize {
    usize::try_from((p >> shift) & ((1u64 << width) - 1)).unwrap_or(0)
}

type Edge = (u32, u32, u8);

fn brute_force(items: &[Item], idx: &[u32], cfg: Config) -> Vec<Edge> {
    (0..idx.len())
        .into_par_iter()
        .flat_map_iter(|i| {
            let a = &items[idx[i] as usize];
            ((i + 1)..idx.len()).filter_map(move |j| {
                compare(a, &items[idx[j] as usize], cfg).map(|s| (idx[i], idx[j], s))
            })
        })
        .collect()
}

/// Pictures: multi-index hashing on the DCT hash. Two hashes within `max_p` bits of each other agree exactly on at
/// least one of `max_p + 1` chunks, so looking only at equal chunks cannot miss a match.
fn image_edges(items: &[Item], idx: &[u32], cfg: Config) -> Vec<Edge> {
    if idx.len() < BRUTE_FORCE_BELOW {
        return brute_force(items, idx, cfg);
    }
    let m = (cfg.max_p + 1).clamp(4, 16);
    let layout = chunks(m);
    // Per chunk: positions sorted by key, and where each key's run starts (counting sort).
    let tables: Vec<(Vec<u32>, Vec<u32>)> = layout
        .iter()
        .map(|&(shift, width)| {
            let buckets = 1usize << width;
            let mut start = vec![0u32; buckets + 1];
            for &g in idx {
                start[chunk_key(items[g as usize].slots[0].p, shift, width) + 1] += 1;
            }
            for k in 0..buckets {
                start[k + 1] += start[k];
            }
            let mut fill = start.clone();
            let mut order = vec![0u32; idx.len()];
            for (pos, &g) in idx.iter().enumerate() {
                let k = chunk_key(items[g as usize].slots[0].p, shift, width);
                order[fill[k] as usize] = u32::try_from(pos).unwrap_or(0);
                fill[k] += 1;
            }
            (order, start)
        })
        .collect();

    // The hashes in two flat arrays: the inner loop below runs billions of times on a big library, and chasing a
    // pointer per candidate is what made it slow. Every picture here is already known to be informative.
    let dct: Vec<u64> = idx.iter().map(|&g| items[g as usize].slots[0].p).collect();
    let diff: Vec<u64> = idx.iter().map(|&g| items[g as usize].slots[0].d).collect();

    (0..idx.len())
        .into_par_iter()
        .map_init(
            || vec![u32::MAX; idx.len()],
            |stamp, i| {
                let me = u32::try_from(i).unwrap_or(u32::MAX);
                let (my_dct, my_diff) = (dct[i], diff[i]);
                let mut found: Vec<Edge> = Vec::new();
                for (c, &(shift, width)) in layout.iter().enumerate() {
                    let k = chunk_key(my_dct, shift, width);
                    let (order, start) = &tables[c];
                    for &j in &order[start[k] as usize..start[k + 1] as usize] {
                        let ju = j as usize;
                        if ju <= i || stamp[ju] == me {
                            continue;
                        }
                        stamp[ju] = me;
                        let near_dct = hamming(my_dct, dct[ju]);
                        if near_dct > cfg.max_p {
                            continue;
                        }
                        let near_diff = hamming(my_diff, diff[ju]);
                        if near_diff <= cfg.max_d {
                            found.push((idx[i], idx[ju], similarity(near_dct, near_diff, 1)));
                        }
                    }
                }
                found
            },
        )
        .flatten_iter()
        .collect()
}

/// Videos: only files of about the same length can match, so sort by length and compare within that window.
fn video_edges(items: &[Item], idx: &[u32], cfg: Config) -> Vec<Edge> {
    let mut by_len: Vec<u32> = idx.iter().copied().filter(|&g| items[g as usize].duration_ms.is_some()).collect();
    by_len.sort_by_key(|&g| items[g as usize].duration_ms);
    let mut edges = Vec::new();
    for (i, &gi) in by_len.iter().enumerate() {
        let a = &items[gi as usize];
        let len = a.duration_ms.unwrap_or(0);
        for &gj in &by_len[i + 1..] {
            let b = &items[gj as usize];
            if b.duration_ms.unwrap_or(0) - len > (b.duration_ms.unwrap_or(0) / 50).max(1_000) {
                break;
            }
            if let Some(s) = compare(a, b, cfg) {
                edges.push((gi, gj, s));
            }
        }
    }
    edges
}

/// Groups files that look like the same shot.
///
/// Every member of a group matches the group's anchor; two members may differ from each other by up to twice the
/// limit. A file belongs to at most one group. Groups made only of byte-identical files are left out (they are
/// exact duplicates). Result order is stable: biggest group first, then lowest anchor id.
#[must_use]
pub fn group(items: &[Item], cfg: Config) -> Vec<Group> {
    let mut images: Vec<u32> = Vec::new();
    let mut videos: Vec<u32> = Vec::new();
    for (i, it) in items.iter().enumerate() {
        if it.slots.is_empty() || it.slots.iter().any(|h| !is_informative(*h)) {
            continue;
        }
        let g = u32::try_from(i).unwrap_or(u32::MAX);
        match it.kind {
            Kind::Image => images.push(g),
            Kind::Video => videos.push(g),
        }
    }
    let mut edges = image_edges(items, &images, cfg);
    edges.extend(video_edges(items, &videos, cfg));

    let mut adjacency: Vec<Vec<(u32, u8)>> = vec![Vec::new(); items.len()];
    for &(a, b, s) in &edges {
        adjacency[a as usize].push((b, s));
        adjacency[b as usize].push((a, s));
    }
    let mut order: Vec<u32> = (0..items.len()).filter(|&i| !adjacency[i].is_empty()).map(|i| u32::try_from(i).unwrap_or(0)).collect();
    order.sort_by_key(|&i| (std::cmp::Reverse(adjacency[i as usize].len()), items[i as usize].id));

    let mut taken = vec![false; items.len()];
    let mut groups: Vec<Group> = Vec::new();
    for anchor in order {
        if taken[anchor as usize] {
            continue;
        }
        let mut members = vec![Member { id: items[anchor as usize].id, similarity: 100 }];
        let mut keys = vec![items[anchor as usize].exact_key];
        let mut near: Vec<(u32, u8)> =
            adjacency[anchor as usize].iter().copied().filter(|&(n, _)| !taken[n as usize]).collect();
        near.sort_by_key(|&(n, s)| (std::cmp::Reverse(s), items[n as usize].id));
        for (n, s) in near {
            members.push(Member { id: items[n as usize].id, similarity: s });
            keys.push(items[n as usize].exact_key);
            taken[n as usize] = true;
        }
        taken[anchor as usize] = true;
        if members.len() < 2 {
            continue;
        }
        let all_identical = keys[0].is_some() && keys.iter().all(|k| *k == keys[0]);
        if !all_identical {
            groups.push(Group { members });
        }
    }
    groups.sort_by_key(|g| (std::cmp::Reverse(g.members.len()), g.members[0].id));
    groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn flip(mut v: u64, bits: &[u32]) -> u64 {
        for b in bits {
            v ^= 1 << b;
        }
        v
    }

    /// A DCT hash with 32 bits set, so it counts as informative.
    const P: u64 = 0x5555_5555_5555_5555;
    const D: u64 = 0x0F0F_0F0F_0F0F_0F0F;

    fn image(id: i64, p: u64, d: u64) -> Item {
        Item { id, kind: Kind::Image, duration_ms: None, exact_key: None, slots: vec![Hash { d, p }] }
    }

    fn video(id: i64, duration: i64, p: u64) -> Item {
        let slots = (0..3).map(|i| Hash { d: flip(D, &[i]), p: flip(p, &[i * 7]) }).collect();
        Item { id, kind: Kind::Video, duration_ms: Some(duration), exact_key: None, slots }
    }

    fn ids(g: &Group) -> Vec<i64> {
        g.members.iter().map(|m| m.id).collect()
    }

    #[test]
    fn close_hashes_match_and_far_ones_do_not() {
        let a = image(1, P, D);
        let near = image(2, flip(P, &[0, 9, 20]), flip(D, &[3, 40]));
        let far = image(3, !P, !D);
        let cfg = Config::default();
        assert_eq!(compare(&a, &a.clone(), cfg), None, "a file never matches itself");
        assert!(compare(&a, &near, cfg).is_some());
        assert_eq!(compare(&a, &far, cfg), None);
        // Both hashes must agree: a close DCT hash with a far difference hash is not a match.
        assert_eq!(compare(&a, &image(4, P, !D), cfg), None);
        assert_eq!(compare(&a, &image(5, !P, D), cfg), None);
    }

    #[test]
    fn similarity_falls_as_distance_grows() {
        let a = image(1, P, D);
        let cfg = Config::default();
        let s = |bits: &[u32]| compare(&a, &image(2, flip(P, bits), D), cfg);
        let (s0, s2, s6) = (s(&[]), s(&[1, 2]), s(&[1, 2, 3, 4, 5, 6]));
        assert_eq!(s0, Some(100));
        assert!(s2 < s0 && s6 < s2, "{s0:?} {s2:?} {s6:?}");
    }

    #[test]
    fn flat_pictures_are_never_matched() {
        let blank_a = image(1, 0, 0);
        let blank_b = image(2, 0, 0);
        assert!(!is_informative(blank_a.slots[0]));
        assert_eq!(compare(&blank_a, &blank_b, Config::default()), None);
        assert!(group(&[blank_a, blank_b], Config::default()).is_empty());
    }

    #[test]
    fn smooth_gradients_are_never_matched() {
        // A smooth gradient has a difference hash of all 0s or all 1s: it says nothing about the picture.
        for d in [0u64, u64::MAX, 0x1FFF_FFFF_FFFF_FFFF] {
            assert!(!is_informative(Hash { d, p: P }), "{d:#x}");
        }
        let a = image(1, P, 0);
        let b = image(2, P, 0);
        assert_eq!(compare(&a, &b, Config::default()), None);
    }

    #[test]
    fn a_chain_does_not_become_one_group() {
        // Five pictures where each matches the next (7 bits apart) but the ends are 28 bits apart.
        let cfg = Config { max_p: 8, max_d: 64 };
        let at = |n: u32| flip(P, &(0..7 * n).collect::<Vec<_>>());
        let items: Vec<Item> = (0..5).map(|n| image(i64::from(n) + 1, at(n), D)).collect();
        assert!(compare(&items[0], &items[1], cfg).is_some());
        assert!(compare(&items[0], &items[2], cfg).is_none());
        let groups = group(&items, cfg);
        assert_eq!(groups.len(), 2, "{groups:?}");
        for g in &groups {
            let set = ids(g);
            assert!(!(set.contains(&1) && set.contains(&5)), "the two ends must not share a group: {set:?}");
            // Everyone in a group matches the anchor.
            let anchor = &items[usize::try_from(set[0]).unwrap() - 1];
            for id in &set[1..] {
                assert!(compare(anchor, &items[usize::try_from(*id).unwrap() - 1], cfg).is_some());
            }
        }
    }

    #[test]
    fn identical_files_alone_make_no_near_group() {
        let mut a = image(1, P, D);
        let mut b = image(2, P, D);
        a.exact_key = Some(7);
        b.exact_key = Some(7);
        assert!(group(&[a.clone(), b.clone()], Config::default()).is_empty());
        // The same pair plus a resized copy is a near group again.
        let mut c = image(3, flip(P, &[4]), D);
        c.exact_key = Some(9);
        let g = group(&[a, b, c], Config::default());
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].members.len(), 3);
    }

    #[test]
    fn videos_need_similar_length_and_all_keyframes() {
        let cfg = Config::default();
        let a = video(1, 60_000, P);
        let same = video(2, 60_400, flip(P, &[2]));
        let longer = video(3, 90_000, P);
        assert!(compare(&a, &same, cfg).is_some());
        assert_eq!(compare(&a, &longer, cfg), None, "a different length is a different video");
        let mut one_bad_frame = video(4, 60_000, P);
        one_bad_frame.slots[1].p = !one_bad_frame.slots[1].p;
        assert_eq!(compare(&a, &one_bad_frame, cfg), None);
        assert_eq!(compare(&a, &image(5, P, D), cfg), None, "a picture is not a video");
        let mut unknown = video(6, 60_000, P);
        unknown.duration_ms = None;
        assert_eq!(compare(&a, &unknown, cfg), None);
    }

    #[test]
    fn video_grouping_uses_the_length_window() {
        let items = vec![video(1, 10_000, P), video(2, 10_050, P), video(3, 500_000, P), video(4, 500_300, P)];
        let groups = group(&items, Config::default());
        let mut sets: Vec<Vec<i64>> = groups.iter().map(ids).collect();
        for s in &mut sets {
            s.sort_unstable();
        }
        sets.sort();
        assert_eq!(sets, vec![vec![1, 2], vec![3, 4]]);
    }

    #[test]
    fn a_file_is_in_at_most_one_group_and_order_is_stable() {
        let items: Vec<Item> = (0..40)
            .map(|i| image(i, flip(P, &[u32::try_from(i % 3).unwrap()]), D))
            .chain((100..104).map(|i| image(i, !P ^ 0xFFFF, !D ^ 0xFF00)))
            .collect();
        let g1 = group(&items, Config::default());
        let g2 = group(&items, Config::default());
        assert_eq!(g1, g2);
        let mut seen = std::collections::HashSet::new();
        for g in &g1 {
            for m in &g.members {
                assert!(seen.insert(m.id), "{} appears twice", m.id);
            }
        }
        assert!(g1.windows(2).all(|w| w[0].members.len() >= w[1].members.len()));
    }

    /// Reference answer: every pair, no index.
    fn all_pairs(items: &[Item], cfg: Config) -> Vec<(i64, i64)> {
        let mut out = Vec::new();
        for (i, a) in items.iter().enumerate() {
            for b in &items[i + 1..] {
                if compare(a, b, cfg).is_some() {
                    out.push((a.id.min(b.id), a.id.max(b.id)));
                }
            }
        }
        out.sort_unstable();
        out
    }

    fn indexed_pairs(items: &[Item], cfg: Config) -> Vec<(i64, i64)> {
        let idx: Vec<u32> = (0..u32::try_from(items.len()).unwrap()).collect();
        let mut out: Vec<(i64, i64)> = {
            // Force the index path regardless of size by calling the index builder through a big enough input.
            let e = if items.len() >= BRUTE_FORCE_BELOW { image_edges(items, &idx, cfg) } else { brute_force(items, &idx, cfg) };
            e.into_iter().map(|(a, b, _)| (items[a as usize].id.min(items[b as usize].id), items[a as usize].id.max(items[b as usize].id))).collect()
        };
        out.sort_unstable();
        out.dedup();
        out
    }

    #[test]
    fn the_index_finds_exactly_the_pairs_a_full_comparison_finds() {
        // 3,000 pictures: random ones plus planted look-alikes at every distance from 0 to 12 bits.
        let mut seed = 0x9E37_79B9_7F4A_7C15u64;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let mut items: Vec<Item> = Vec::new();
        for i in 0..2_700 {
            let (p, d) = (next(), next());
            if is_informative(Hash { d, p }) {
                items.push(image(i, p, d));
            }
        }
        for k in 0..300u32 {
            let base = items[(k as usize * 7) % items.len()].clone();
            let bits: Vec<u32> = (0..(k % 13)).map(|b| (b * 5 + k) % 64).collect();
            let d_bits: Vec<u32> = (0..(k % 5)).map(|b| (b * 11 + k) % 64).collect();
            items.push(image(10_000 + i64::from(k), flip(base.slots[0].p, &bits), flip(base.slots[0].d, &d_bits)));
        }
        assert!(items.len() >= BRUTE_FORCE_BELOW);
        let cfg = Config::default();
        let want = all_pairs(&items, cfg);
        assert!(want.len() > 100, "the planted pairs must be found by the reference: {}", want.len());
        assert_eq!(indexed_pairs(&items, cfg), want);
    }

    /// `cargo test -p sa-dedupe --release -- --ignored --nocapture`
    #[test]
    #[ignore = "benchmark: groups 250,000 pictures"]
    fn bench_group_250k_pictures() {
        let mut seed = 0x1234_5678_9ABC_DEF1u64;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let mut items: Vec<Item> = Vec::new();
        while items.len() < 250_000 {
            let (p, d) = (next(), next());
            if is_informative(Hash { d, p }) {
                items.push(image(i64::try_from(items.len()).unwrap(), p, d));
            }
        }
        // 5 % of the library has a look-alike.
        for k in 0..12_500usize {
            let base = items[k * 20].clone();
            let k32 = u32::try_from(k).unwrap();
            let bits: Vec<u32> = (0..k32 % 9).map(|b| (b * 7 + k32) % 64).collect();
            items.push(image(1_000_000 + i64::try_from(k).unwrap(), flip(base.slots[0].p, &bits), base.slots[0].d));
        }
        let started = std::time::Instant::now();
        let groups = group(&items, Config::default());
        println!("grouped {} pictures into {} groups in {:?}", items.len(), groups.len(), started.elapsed());
        assert!(groups.len() >= 12_000);
    }

    proptest! {
        #[test]
        fn grouping_never_loses_or_repeats_a_file(
            hashes in prop::collection::vec((any::<u64>(), any::<u64>()), 0..60),
            flips in prop::collection::vec(0u32..12, 0..30),
        ) {
            let mut items: Vec<Item> = hashes.iter().enumerate()
                .map(|(i, (p, d))| image(i64::try_from(i).unwrap(), *p, *d)).collect();
            for (k, n) in flips.iter().enumerate() {
                if let Some(b) = items.get(k).cloned() {
                    let bits: Vec<u32> = (0..*n).map(|x| (x * 3 + 1) % 64).collect();
                    items.push(image(1_000 + i64::try_from(k).unwrap(), flip(b.slots[0].p, &bits), b.slots[0].d));
                }
            }
            let groups = group(&items, Config::default());
            let mut seen = std::collections::HashSet::new();
            for g in &groups {
                prop_assert!(g.members.len() >= 2);
                prop_assert_eq!(g.members[0].similarity, 100);
                for m in &g.members {
                    prop_assert!(seen.insert(m.id));
                    prop_assert!(items.iter().any(|i| i.id == m.id));
                }
            }
        }
    }
}
