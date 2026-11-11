//! Phase 3, decision D5: exact scan against HNSW on REAL embeddings, and memory that is measured rather than computed.
//!
//!   real recall <dump-dir> [dims=768] [max_queries=2000]
//!       Loads a dump made by an embedding harness (the format `eval` reads), truncates and re-normalises to `dims`, and for
//!       every query compares: exact f32 (the ground truth for "what the index should return"), exact f16-stored, exact int8,
//!       and HNSW (M = 16, several ef). Reports agreement with exact f32 top-10, the task's own hit@10 / MRR@10 for each
//!       method (so an approximation's cost on the real task is visible), and query latency.
//!   real memory <dims> <n>
//!       Allocates n vectors in each representation and reports the process's resident size after each step next to the
//!       computed byte count. Memory does not depend on the values, so synthetic vectors are used for the large sizes.
//!
//! Throwaway research code, safe Rust only. Resident size comes from `ps`, so it includes allocator slack: that is the point.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Instant;
use vector_bench::*;

fn read_f32(path: &Path) -> Vec<f32> {
    let b = fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

fn json_field(meta: &str, key: &str) -> Option<String> {
    let at = meta.find(&format!("\"{key}\""))?;
    let rest = &meta[at + key.len() + 2..];
    let rest = rest.trim_start().strip_prefix(':')?.trim_start();
    let end = rest.find([',', '}']).unwrap_or(rest.len());
    Some(rest[..end].trim().trim_matches('"').to_string())
}

/// `[[1,2],[3],[]]` -> vec of vecs. Enough JSON for this one shape.
fn parse_relevance(s: &str) -> Vec<Vec<usize>> {
    let mut out = Vec::new();
    let mut cur: Option<Vec<usize>> = None;
    let mut num = String::new();
    let mut depth = 0;
    let flush = |num: &mut String, cur: &mut Option<Vec<usize>>| {
        if !num.is_empty() {
            if let Some(c) = cur.as_mut() {
                c.push(num.parse().unwrap_or(0));
            }
            num.clear();
        }
    };
    for ch in s.chars() {
        match ch {
            '[' => {
                depth += 1;
                if depth == 2 {
                    cur = Some(Vec::new());
                }
            }
            ']' => {
                flush(&mut num, &mut cur);
                if depth == 2 {
                    out.push(cur.take().unwrap_or_default());
                }
                depth -= 1;
            }
            '0'..='9' => num.push(ch),
            _ => flush(&mut num, &mut cur),
        }
    }
    out
}

fn truncate(v: &[f32], dims: usize, to: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(v.len() / dims * to);
    for row in v.chunks_exact(dims) {
        let mut r = row[..to].to_vec();
        let n = r.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
        r.iter_mut().for_each(|x| *x /= n);
        out.extend(r);
    }
    out
}

fn rss_mb() -> f64 {
    let pid = std::process::id().to_string();
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid]).output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    out.ok().and_then(|s| s.parse::<f64>().ok()).map_or(f64::NAN, |kb| kb / 1024.0)
}

/// Hit@10 and reciprocal rank (within 10) of one ranked list against the relevant set.
fn score(ranked: &[u32], rel: &[usize]) -> (f64, f64) {
    match ranked.iter().take(10).position(|i| rel.contains(&(*i as usize))) {
        Some(r) => (1.0, 1.0 / (r as f64 + 1.0)),
        None => (0.0, 0.0),
    }
}

#[derive(Default)]
struct Tally {
    agree: f64,
    /// Agreement with the exact int8 scan: for an index built on int8 vectors this isolates the graph's own error from quantisation.
    agree_i8: f64,
    hit: f64,
    mrr: f64,
    us: Vec<f64>,
}
impl Tally {
    fn add(&mut self, found: &[u32], truth: &[u32], truth_i8: &[u32], rel: &[usize], micros: f64) {
        self.agree += recall(found, truth);
        self.agree_i8 += recall(found, truth_i8);
        let (h, m) = score(found, rel);
        self.hit += h;
        self.mrr += m;
        self.us.push(micros);
    }
    fn line(&mut self, name: &str, n: usize) {
        self.us.sort_by(f64::total_cmp);
        println!(
            "  {name:<28} vs f32 {:>6.4}   vs int8 {:>6.4}   hit@10 {:>6.4}   MRR@10 {:>6.4}   p50 {:>8.0} µs   p95 {:>8.0} µs",
            self.agree / n as f64,
            self.agree_i8 / n as f64,
            self.hit / n as f64,
            self.mrr / n as f64,
            percentile(&self.us, 0.5),
            percentile(&self.us, 0.95)
        );
    }
}

fn recall_cmd(dir: &Path, to_dims: usize, max_queries: usize) {
    let meta = fs::read_to_string(dir.join("meta.json")).expect("meta.json");
    let dims: usize = json_field(&meta, "dims").and_then(|s| s.parse().ok()).expect("dims in meta.json");
    let task = json_field(&meta, "task").unwrap_or_default();
    let runtime = json_field(&meta, "runtime").unwrap_or_default();
    let corpus = truncate(&read_f32(&dir.join("corpus.f32")), dims, to_dims);
    let all_q = truncate(&read_f32(&dir.join("queries.f32")), dims, to_dims);
    let relevant = parse_relevance(&fs::read_to_string(dir.join("relevance.json")).expect("relevance.json"));
    let n = corpus.len() / to_dims;
    // An even spread of queries rather than the first ones, so a sorted dump is not biased.
    let total_q = all_q.len() / to_dims;
    let step = (total_q / max_queries.max(1)).max(1);
    let picks: Vec<usize> = (0..total_q).step_by(step).take(max_queries).collect();
    println!("\n== {task} | {runtime}\n   {n} corpus vectors, {} of {total_q} queries, {to_dims} dims, k = 10, {} cores", picks.len(), std::thread::available_parallelism().map_or(0, |c| c.get()));

    let f16: Vec<f32> = corpus.iter().map(|&x| f16_to_f32(f32_to_f16(x))).collect();
    let q8 = Int8Vecs::from_f32(&corpus, to_dims);
    let t = Instant::now();
    let h = Hnsw::build(&q8, 16, 100);
    println!("   HNSW M=16 efConstruction=100 build: {:.2} s, graph {} B/vector", t.elapsed().as_secs_f64(), h.graph_bytes() / n.max(1));

    let k = 10;
    let mut exact_f32_t = Tally::default();
    let mut exact_f16_t = Tally::default();
    let mut exact_i8_t = Tally::default();
    let efs = [16usize, 32, 64, 128, 256];
    let mut hnsw_t: Vec<Tally> = efs.iter().map(|_| Tally::default()).collect();
    let mut vis = Visited::new(n);
    for &qi in &picks {
        let q = &all_q[qi * to_dims..(qi + 1) * to_dims];
        let rel = &relevant[qi];
        if rel.is_empty() {
            continue;
        }
        let t = Instant::now();
        let truth = exact_f32(&corpus, to_dims, q, k, None);
        let us_f32 = t.elapsed().as_secs_f64() * 1e6;

        let t = Instant::now();
        let r_f16 = exact_f32(&f16, to_dims, q, k, None);
        let us_f16 = t.elapsed().as_secs_f64() * 1e6;

        let qq = Int8Vecs::from_f32(q, to_dims);
        let t = Instant::now();
        let r_i8 = exact_i8_parallel(&q8, qq.row(0), qq.scale[0], k, None);
        let us_i8 = t.elapsed().as_secs_f64() * 1e6;

        exact_f32_t.add(&truth, &truth, &r_i8, rel, us_f32);
        exact_f16_t.add(&r_f16, &truth, &r_i8, rel, us_f16);
        exact_i8_t.add(&r_i8, &truth, &r_i8, rel, us_i8);
        for (e, tally) in efs.iter().zip(hnsw_t.iter_mut()) {
            let t = Instant::now();
            let r = h.search(qq.row(0), qq.scale[0], k, *e, &mut vis, None);
            tally.add(&r, &truth, &r_i8, rel, t.elapsed().as_secs_f64() * 1e6);
        }
    }
    let counted = exact_f32_t.us.len();
    println!("   ({counted} queries with at least one relevant item; 'vs f32' / 'vs int8' = share of the exact f32 / exact int8 top-10 that the method also returns)");
    exact_f32_t.line("exact f32 (1 thread)", counted);
    exact_f16_t.line("exact f16-stored (1 thread)", counted);
    exact_i8_t.line("exact int8 (all cores)", counted);
    for (e, tally) in efs.iter().zip(hnsw_t.iter_mut()) {
        tally.line(&format!("HNSW ef={e}"), counted);
    }
}

fn memory_cmd(dims: usize, n: usize) {
    println!("\n== Measured resident memory for {n} vectors at {dims} dims (process RSS from ps; computed bytes beside it)");
    let base = rss_mb();
    println!("  baseline process: {base:.1} MB");
    let data = make_data(n, dims, (n / 50).max(10), 0.9, 7);
    let after_f32 = rss_mb();
    let computed_f32 = (n * dims * 4) as f64 / 1_048_576.0;
    println!("  f32 matrix        measured {:>9.1} MB   computed {computed_f32:>9.1} MB", after_f32 - base);

    let f16: Vec<u16> = data.iter().map(|&x| f32_to_f16(x)).collect();
    let after_f16 = rss_mb();
    let computed_f16 = (n * dims * 2) as f64 / 1_048_576.0;
    println!("  f16 matrix        measured {:>9.1} MB   computed {computed_f16:>9.1} MB", after_f16 - after_f32);

    let q8 = Int8Vecs::from_f32(&data, dims);
    let after_i8 = rss_mb();
    let computed_i8 = (n * (dims + 4)) as f64 / 1_048_576.0;
    println!("  int8 + scale      measured {:>9.1} MB   computed {computed_i8:>9.1} MB", after_i8 - after_f16);

    // The graph is built while the f32 source is still alive, so none of its memory can be recycled from freed f32 pages.
    let t = Instant::now();
    let h = Hnsw::build(&q8, 16, 100);
    let build = t.elapsed().as_secs_f64();
    let after_graph = rss_mb();
    let computed_graph = h.graph_bytes() as f64 / 1_048_576.0;
    println!(
        "  HNSW graph (M=16) measured {:>8.1} MB   computed {computed_graph:>9.1} MB   ({} B/vector computed; built in {build:.1} s)",
        after_graph - after_i8,
        h.graph_bytes() / n.max(1)
    );

    let computed_kept = computed_f16 + computed_i8 + computed_graph;
    let measured_all = after_graph - base;
    println!("  everything alive: measured {measured_all:.1} MB, computed sum {:.1} MB (f32 {computed_f32:.1} + f16 + int8 + graph)", computed_f32 + computed_kept);

    drop(data);
    std::thread::sleep(std::time::Duration::from_secs(3));
    let after_drop = rss_mb();
    println!(
        "  f32 source dropped, 3 s later: resident {:.1} MB (change {:+.1} MB); the f16 + int8 + graph that remain compute to {computed_kept:.1} MB",
        after_drop - base,
        after_drop - after_graph
    );
    println!("  (kept alive to the end: {} f16 values, {} int8 vectors)", f16.len(), q8.len());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("recall") => {
            let dir = args.get(2).expect("dump dir");
            let dims = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(768);
            let max_q = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(2000);
            recall_cmd(Path::new(dir), dims, max_q);
        }
        Some("memory") => {
            let dims = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(768);
            let n = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(100_000);
            memory_cmd(dims, n);
        }
        _ => eprintln!("usage: real recall <dump-dir> [dims] [max_queries]   |   real memory <dims> <n>"),
    }
}
