//! Throwaway Phase 3 vector code: int8 quantisation, exact scan, a small HNSW, and a safe-Rust RNG. Not shipped.
//! Shared by the synthetic spike (`vector-bench`) and the real-embedding benchmark (`real`).

use rayon::prelude::*;

// ---------- deterministic randomness ----------
pub struct Rng(pub u64);
impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    pub fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u64 << 24) as f32
    }
    /// Approximately standard normal (sum of uniforms).
    pub fn gauss(&mut self) -> f32 {
        (0..6).map(|_| self.unit()).sum::<f32>() - 3.0
    }
}

pub fn normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
    v.iter_mut().for_each(|x| *x /= n);
}

/// `n` unit vectors in `clusters` clusters: a centre plus noise, like photos of the same scene.
pub fn make_data(n: usize, dims: usize, clusters: usize, noise: f32, seed: u64) -> Vec<f32> {
    let mut rng = Rng(seed);
    let centres: Vec<Vec<f32>> = (0..clusters)
        .map(|_| {
            let mut c: Vec<f32> = (0..dims).map(|_| rng.gauss()).collect();
            normalize(&mut c);
            c
        })
        .collect();
    let mut out = Vec::with_capacity(n * dims);
    for i in 0..n {
        let c = &centres[(rng.next() as usize + i) % clusters];
        let mut v: Vec<f32> = c.iter().map(|x| x + noise * rng.gauss() / (dims as f32).sqrt()).collect();
        normalize(&mut v);
        out.extend(v);
    }
    out
}

// ---------- storage formats ----------
/// IEEE half precision, round to nearest even, no NaN payload handling (inputs are finite unit-vector entries).
pub fn f32_to_f16(x: f32) -> u16 {
    let b = x.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xFF) as i32 - 127 + 15;
    let man = b & 0x007F_FFFF;
    if exp <= 0 {
        if exp < -10 {
            return sign;
        }
        let m = (man | 0x0080_0000) >> (1 - exp);
        return sign | ((m + 0x1000) >> 13) as u16;
    }
    if exp >= 31 {
        return sign | 0x7C00;
    }
    let half = sign | ((exp as u16) << 10) | (man >> 13) as u16;
    half + (((man >> 12) & 1) as u16 & (((man & 0xFFF) != 0) as u16 | (half & 1)))
}

pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h & 0x8000) as u32) << 16;
    let exp = ((h >> 10) & 0x1F) as u32;
    let man = (h & 0x3FF) as u32;
    let bits = if exp == 0 {
        if man == 0 {
            sign
        } else {
            let shift = man.leading_zeros() - 21;
            sign | ((113 - shift) << 23) | (((man << shift) & 0x3FF) << 13)
        }
    } else if exp == 31 {
        sign | 0x7F80_0000 | (man << 13)
    } else {
        sign | ((exp + 112) << 23) | (man << 13)
    };
    f32::from_bits(bits)
}

/// int8 with one scale per vector: value = q * scale.
pub struct Int8Vecs {
    pub dims: usize,
    pub q: Vec<i8>,
    pub scale: Vec<f32>,
}

impl Int8Vecs {
    pub fn from_f32(data: &[f32], dims: usize) -> Self {
        let n = data.len() / dims;
        let mut q = Vec::with_capacity(data.len());
        let mut scale = Vec::with_capacity(n);
        for v in data.chunks_exact(dims) {
            let max = v.iter().fold(0f32, |m, x| m.max(x.abs())).max(1e-9);
            let s = max / 127.0;
            scale.push(s);
            q.extend(v.iter().map(|x| (x / s).round().clamp(-127.0, 127.0) as i8));
        }
        Self { dims, q, scale }
    }
    pub fn row(&self, i: usize) -> &[i8] {
        &self.q[i * self.dims..(i + 1) * self.dims]
    }
    pub fn len(&self) -> usize {
        self.scale.len()
    }
}

#[inline]
pub fn dot_i8(a: &[i8], b: &[i8]) -> i32 {
    // Written so the compiler vectorizes it (widening multiply-add in 16 lanes).
    a.chunks_exact(16)
        .zip(b.chunks_exact(16))
        .map(|(x, y)| x.iter().zip(y).map(|(p, q)| i32::from(*p) * i32::from(*q)).sum::<i32>())
        .sum()
}

#[inline]
pub fn dot_f32(a: &[f32], b: &[f32]) -> f32 {
    a.chunks_exact(16).zip(b.chunks_exact(16)).map(|(x, y)| x.iter().zip(y).map(|(p, q)| p * q).sum::<f32>()).sum()
}

// ---------- exact search ----------
pub fn top_k(scores: impl Iterator<Item = (u32, f32)>, k: usize) -> Vec<u32> {
    let mut best: Vec<(u32, f32)> = Vec::with_capacity(k + 1);
    for (id, s) in scores {
        if best.len() < k || s > best[best.len() - 1].1 {
            let pos = best.partition_point(|(_, b)| *b >= s);
            best.insert(pos, (id, s));
            best.truncate(k);
        }
    }
    best.into_iter().map(|(i, _)| i).collect()
}

pub fn exact_f32(data: &[f32], dims: usize, q: &[f32], k: usize, allow: Option<&[u32]>) -> Vec<u32> {
    let n = data.len() / dims;
    match allow {
        None => top_k((0..n as u32).map(|i| (i, dot_f32(&data[i as usize * dims..(i as usize + 1) * dims], q))), k),
        Some(ids) => top_k(ids.iter().map(|&i| (i, dot_f32(&data[i as usize * dims..(i as usize + 1) * dims], q))), k),
    }
}

/// Exact scan over int8 vectors on all cores (what a narrow-filter search would do).
pub fn exact_i8_parallel(v: &Int8Vecs, q: &[i8], qs: f32, k: usize, allow: Option<&[u32]>) -> Vec<u32> {
    let score = |i: u32| (i, dot_i8(v.row(i as usize), q) as f32 * v.scale[i as usize] * qs);
    let chunk = 8192;
    let parts: Vec<Vec<(u32, f32)>> = match allow {
        None => (0..v.len() as u32)
            .into_par_iter()
            .chunks(chunk)
            .map(|ids| top_scored(ids.into_iter().map(score), k))
            .collect(),
        Some(ids) => ids.par_chunks(chunk).map(|c| top_scored(c.iter().copied().map(score), k)).collect(),
    };
    let mut all: Vec<(u32, f32)> = parts.into_iter().flatten().collect();
    all.sort_by(|a, b| b.1.total_cmp(&a.1));
    all.truncate(k);
    all.into_iter().map(|(i, _)| i).collect()
}

pub fn top_scored(scores: impl Iterator<Item = (u32, f32)>, k: usize) -> Vec<(u32, f32)> {
    let mut best: Vec<(u32, f32)> = Vec::with_capacity(k + 1);
    for (id, s) in scores {
        if best.len() < k || s > best[best.len() - 1].1 {
            let pos = best.partition_point(|(_, b)| *b >= s);
            best.insert(pos, (id, s));
            best.truncate(k);
        }
    }
    best
}

// ---------- HNSW over int8 vectors ----------
pub struct Hnsw<'a> {
    pub v: &'a Int8Vecs,
    pub m: usize,
    /// level 0: stride (2m + 1) entries per node: [count, neighbours...]
    pub l0: Vec<u32>,
    /// upper levels: per node, per level, neighbour lists (rare: ~1/m of nodes have level >= 1)
    pub upper: Vec<Vec<Vec<u32>>>,
    pub levels: Vec<u8>,
    pub entry: u32,
    pub max_level: usize,
}

pub struct Visited {
    pub mark: Vec<u32>,
    pub epoch: u32,
}
impl Visited {
    pub fn new(n: usize) -> Self {
        Self { mark: vec![0; n], epoch: 0 }
    }
    pub fn next(&mut self) {
        self.epoch += 1;
    }
    pub fn seen(&mut self, i: u32) -> bool {
        let s = self.mark[i as usize] == self.epoch;
        self.mark[i as usize] = self.epoch;
        s
    }
}

impl<'a> Hnsw<'a> {
    pub fn dist(&self, a: u32, b: u32) -> f32 {
        let d = dot_i8(self.v.row(a as usize), self.v.row(b as usize)) as f32 * self.v.scale[a as usize] * self.v.scale[b as usize];
        1.0 - d
    }
    pub fn dist_q(&self, q: &[i8], qs: f32, b: u32) -> f32 {
        1.0 - dot_i8(q, self.v.row(b as usize)) as f32 * qs * self.v.scale[b as usize]
    }
    pub fn neighbours(&self, node: u32, level: usize) -> &[u32] {
        if level == 0 {
            let s = node as usize * (2 * self.m + 1);
            let c = self.l0[s] as usize;
            &self.l0[s + 1..s + 1 + c]
        } else {
            &self.upper[node as usize][level - 1]
        }
    }

    pub fn build(v: &'a Int8Vecs, m: usize, ef_construction: usize) -> Self {
        let n = v.len();
        let mut rng = Rng(0xABCDEF);
        let ml = 1.0 / (m as f32).ln();
        let levels: Vec<u8> = (0..n).map(|_| ((-(rng.unit().max(1e-9)).ln() * ml) as usize).min(8) as u8).collect();
        let mut h = Self {
            v,
            m,
            l0: vec![0; n * (2 * m + 1)],
            upper: levels.iter().map(|&l| vec![Vec::new(); l as usize]).collect(),
            levels: levels.clone(),
            entry: 0,
            max_level: levels[0] as usize,
        };
        let mut vis = Visited::new(n);
        for node in 1..n as u32 {
            let level = levels[node as usize] as usize;
            let q = v.row(node as usize);
            let qs = v.scale[node as usize];
            let mut ep = h.entry;
            for l in (level + 1..=h.max_level).rev() {
                ep = h.greedy(q, qs, ep, l);
            }
            let mut eps = vec![ep];
            for l in (0..=level.min(h.max_level)).rev() {
                let found = h.search_layer(q, qs, &eps, ef_construction, l, &mut vis, None);
                let cap = if l == 0 { 2 * m } else { m };
                let chosen = h.select(&found, cap);
                for &(_, nb) in &chosen {
                    h.link(node, nb, l);
                    h.link(nb, node, l);
                }
                eps = found.iter().map(|&(_, i)| i).collect();
            }
            if level > h.max_level {
                h.max_level = level;
                h.entry = node;
            }
        }
        h
    }

    pub fn greedy(&self, q: &[i8], qs: f32, mut cur: u32, level: usize) -> u32 {
        let mut best = self.dist_q(q, qs, cur);
        loop {
            let mut moved = false;
            for &nb in self.neighbours(cur, level) {
                let d = self.dist_q(q, qs, nb);
                if d < best {
                    best = d;
                    cur = nb;
                    moved = true;
                }
            }
            if !moved {
                return cur;
            }
        }
    }

    /// Best-first search in one layer. Returns (distance, id) ascending. `allow` filters results, not the walk.
    pub fn search_layer(
        &self,
        q: &[i8],
        qs: f32,
        eps: &[u32],
        ef: usize,
        level: usize,
        vis: &mut Visited,
        allow: Option<&dyn Fn(u32) -> bool>,
    ) -> Vec<(f32, u32)> {
        vis.next();
        let mut cand: Vec<(f32, u32)> = Vec::new(); // kept sorted descending so pop() is the closest
        let mut result: Vec<(f32, u32)> = Vec::new(); // ascending
        for &e in eps {
            vis.seen(e);
            let d = self.dist_q(q, qs, e);
            cand.push((d, e));
            if allow.is_none_or(|f| f(e)) {
                result.push((d, e));
            }
        }
        cand.sort_by(|a, b| b.0.total_cmp(&a.0));
        result.sort_by(|a, b| a.0.total_cmp(&b.0));
        while let Some((d, c)) = cand.pop() {
            if result.len() >= ef && d > result[result.len() - 1].0 {
                break;
            }
            for &nb in self.neighbours(c, level) {
                if vis.seen(nb) {
                    continue;
                }
                let dn = self.dist_q(q, qs, nb);
                if result.len() < ef || dn < result[result.len() - 1].0 {
                    let pos = cand.partition_point(|x| x.0 > dn);
                    cand.insert(pos, (dn, nb));
                    if allow.is_none_or(|f| f(nb)) {
                        let rp = result.partition_point(|x| x.0 <= dn);
                        result.insert(rp, (dn, nb));
                        result.truncate(ef);
                    }
                }
            }
        }
        result
    }

    /// The usual diversity heuristic: keep a candidate only if it is closer to the new node than to anything kept.
    pub fn select(&self, found: &[(f32, u32)], cap: usize) -> Vec<(f32, u32)> {
        let mut out: Vec<(f32, u32)> = Vec::with_capacity(cap);
        for &(d, c) in found {
            if out.len() >= cap {
                break;
            }
            if out.iter().all(|&(_, o)| self.dist(c, o) > d) {
                out.push((d, c));
            }
        }
        for &(d, c) in found {
            if out.len() >= cap {
                break;
            }
            if !out.iter().any(|&(_, o)| o == c) {
                out.push((d, c));
            }
        }
        out
    }

    pub fn link(&mut self, from: u32, to: u32, level: usize) {
        if from == to {
            return;
        }
        let cap = if level == 0 { 2 * self.m } else { self.m };
        if level == 0 {
            let s = from as usize * (2 * self.m + 1);
            let c = self.l0[s] as usize;
            if self.l0[s + 1..s + 1 + c].contains(&to) {
                return;
            }
            if c < cap {
                self.l0[s + 1 + c] = to;
                self.l0[s] += 1;
                return;
            }
            let mut all: Vec<(f32, u32)> = self.l0[s + 1..s + 1 + c].iter().map(|&x| (self.dist(from, x), x)).collect();
            all.push((self.dist(from, to), to));
            all.sort_by(|a, b| a.0.total_cmp(&b.0));
            let keep = self.select(&all, cap);
            self.l0[s] = keep.len() as u32;
            for (i, &(_, x)) in keep.iter().enumerate() {
                self.l0[s + 1 + i] = x;
            }
        } else {
            let list = &self.upper[from as usize][level - 1];
            if list.contains(&to) {
                return;
            }
            if list.len() < cap {
                self.upper[from as usize][level - 1].push(to);
                return;
            }
            let mut all: Vec<(f32, u32)> = list.iter().map(|&x| (self.dist(from, x), x)).collect();
            all.push((self.dist(from, to), to));
            all.sort_by(|a, b| a.0.total_cmp(&b.0));
            let keep: Vec<u32> = self.select(&all, cap).into_iter().map(|(_, x)| x).collect();
            self.upper[from as usize][level - 1] = keep;
        }
    }

    pub fn search(&self, q: &[i8], qs: f32, k: usize, ef: usize, vis: &mut Visited, allow: Option<&dyn Fn(u32) -> bool>) -> Vec<u32> {
        let mut ep = self.entry;
        for l in (1..=self.max_level).rev() {
            ep = self.greedy(q, qs, ep, l);
        }
        let r = self.search_layer(q, qs, &[ep], ef.max(k), 0, vis, allow);
        r.into_iter().take(k).map(|(_, i)| i).collect()
    }

    /// Bytes the graph takes if stored compactly: 4 bytes per neighbour slot at level 0 (fixed stride) plus upper levels.
    pub fn graph_bytes(&self) -> usize {
        let upper: usize = self.upper.iter().flatten().map(|l| l.len() * 4 + 4).sum();
        self.l0.len() * 4 + upper + self.levels.len()
    }
}

// ---------- the experiments ----------
pub fn recall(found: &[u32], truth: &[u32]) -> f64 {
    let hit = found.iter().filter(|f| truth.contains(f)).count();
    hit as f64 / truth.len().max(1) as f64
}

pub fn percentile(sorted_us: &[f64], p: f64) -> f64 {
    sorted_us[((sorted_us.len() - 1) as f64 * p) as usize]
}

