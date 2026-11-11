//! Usage: vector-bench [dims] [max_n] [noise]   (default 512 dims, up to 250,000 vectors, noise 0.9)
//! noise ~0.9 gives clusters whose members are ~0.6 cosine apart (embedding-like); noise ~6 is nearly random (worst case).
//!
//! Synthetic, clustered unit vectors stand in for embeddings. Speed and storage do not depend on the vectors; HNSW
//! recall does, so the recall numbers are re-checked on real EmbeddingGemma 2 vectors once a runtime has produced them.

use std::time::Instant;
use vector_bench::*;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dims: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(512);
    let max_n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(250_000);
    let noise: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0.9);
    let k = 10;
    println!("noise {noise}; dims {dims}, up to {max_n} vectors, k = {k}, {} cores", std::thread::available_parallelism().map_or(0, |n| n.get()));

    // --- 1. storage cost per vector ---
    let f32_bytes = dims * 4;
    let f16_bytes = dims * 2;
    let i8_bytes = dims + 4;
    println!("\n== Storage per vector at {dims} dims");
    println!("  f32 {f32_bytes} B | f16 (SQLite blob) {f16_bytes} B | int8 + scale (HNSW) {i8_bytes} B");

    // --- 2. f16 round-trip and int8 quantization error on the ranking ---
    let n_q = 20_000.min(max_n);
    let data = make_data(n_q, dims, (n_q / 50).max(10), noise, 7);
    let f16: Vec<f32> = data.iter().map(|&x| f16_to_f32(f32_to_f16(x))).collect();
    let max_err = data.iter().zip(&f16).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
    println!("  f16 round-trip: worst component error {max_err:.2e} (unit-vector entries; f16 is safe for STORING embeddings)");
    let q8 = Int8Vecs::from_f32(&data, dims);
    let queries: Vec<usize> = (0..500).map(|i| (i * 37) % n_q).collect();
    let mut agree_f16 = 0.0;
    let mut agree_i8 = 0.0;
    for &qi in &queries {
        let q = &data[qi * dims..(qi + 1) * dims];
        let truth = exact_f32(&data, dims, q, k, None);
        agree_f16 += recall(&exact_f32(&f16, dims, q, k, None), &truth);
        let qq = Int8Vecs::from_f32(q, dims);
        agree_i8 += recall(&exact_i8_parallel(&q8, qq.row(0), qq.scale[0], k, None), &truth);
    }
    println!(
        "  top-{k} agreement with exact f32 over {n_q} vectors: f16 {:.4}, int8 {:.4}",
        agree_f16 / queries.len() as f64,
        agree_i8 / queries.len() as f64
    );

    // --- 3. brute force vs HNSW across sizes ---
    println!("\n== Search time by library size (k = {k}; HNSW M = 16, efConstruction = 100)");
    println!("  {:>8} | {:>11} {:>11} | {:>9} {:>9} {:>9} | {:>10} {:>10} | {:>9}", "vectors", "exact p50", "exact p95", "ef", "hnsw p50", "hnsw p95", "recall@10", "build", "graph B/v");
    let sizes: Vec<usize> = [1_000, 5_000, 10_000, 20_000, 50_000, 100_000, 250_000].into_iter().filter(|&s| s <= max_n).collect();
    let full = make_data(*sizes.last().unwrap_or(&1000), dims, (sizes.last().copied().unwrap_or(1000) / 50).max(10), noise, 11);
    for &n in &sizes {
        let data = &full[..n * dims];
        let q8 = Int8Vecs::from_f32(data, dims);
        let qids: Vec<usize> = (0..200).map(|i| (i * 7919 + 13) % n).collect();
        // exact int8 scan on all cores
        let mut ex_us = Vec::new();
        let mut truths = Vec::new();
        for &qi in &qids {
            let qq = Int8Vecs::from_f32(&data[qi * dims..(qi + 1) * dims], dims);
            let t = Instant::now();
            let r = exact_i8_parallel(&q8, qq.row(0), qq.scale[0], k, None);
            ex_us.push(t.elapsed().as_secs_f64() * 1e6);
            truths.push((qq, r));
        }
        ex_us.sort_by(f64::total_cmp);
        let t = Instant::now();
        let h = Hnsw::build(&q8, 16, 100);
        let build = t.elapsed();
        let mut vis = Visited::new(n);
        for ef in [32usize, 64, 128] {
            let mut us = Vec::new();
            let mut rec = 0.0;
            for (qq, truth) in &truths {
                let t = Instant::now();
                let r = h.search(qq.row(0), qq.scale[0], k, ef, &mut vis, None);
                us.push(t.elapsed().as_secs_f64() * 1e6);
                rec += recall(&r, truth);
            }
            us.sort_by(f64::total_cmp);
            println!(
                "  {:>8} | {:>9.0}µs {:>9.0}µs | {:>9} {:>7.0}µs {:>7.0}µs | {:>10.4} {:>9.1}s | {:>9}",
                n, percentile(&ex_us, 0.5), percentile(&ex_us, 0.95), ef, percentile(&us, 0.5), percentile(&us, 0.95),
                rec / truths.len() as f64, build.as_secs_f64(), h.graph_bytes() / n
            );
        }
    }

    // --- 4. filtered search: when to scan instead of walking the graph ---
    let n = *sizes.last().unwrap_or(&1000);
    let data = &full[..n * dims];
    let q8 = Int8Vecs::from_f32(data, dims);
    let h = Hnsw::build(&q8, 16, 100);
    println!("\n== Filtered search at {n} vectors (k = {k}): graph walk with the filter vs exact scan of only the matching vectors");
    println!("  {:>10} {:>9} | {:>11} | {:>10} {:>10} {:>10}", "matching", "share", "scan p50", "hnsw ef=64", "recall", "ef=256 rec");
    let mut vis = Visited::new(n);
    for share in [0.001f64, 0.005, 0.02, 0.05, 0.2, 0.5] {
        let mut rng = Rng(99);
        let allow: Vec<u32> = (0..n as u32).filter(|_| (rng.unit() as f64) < share).collect();
        let mask: Vec<bool> = {
            let mut m = vec![false; n];
            allow.iter().for_each(|&i| m[i as usize] = true);
            m
        };
        let pred = |i: u32| mask[i as usize];
        let mut scan_us = Vec::new();
        let (mut us64, mut r64, mut r256) = (Vec::new(), 0.0, 0.0);
        let qids: Vec<usize> = (0..100).map(|i| (i * 104_729 + 5) % n).collect();
        for &qi in &qids {
            let qq = Int8Vecs::from_f32(&data[qi * dims..(qi + 1) * dims], dims);
            let t = Instant::now();
            let truth = exact_i8_parallel(&q8, qq.row(0), qq.scale[0], k, Some(&allow));
            scan_us.push(t.elapsed().as_secs_f64() * 1e6);
            let t = Instant::now();
            let r = h.search(qq.row(0), qq.scale[0], k, 64, &mut vis, Some(&pred));
            us64.push(t.elapsed().as_secs_f64() * 1e6);
            r64 += recall(&r, &truth);
            r256 += recall(&h.search(qq.row(0), qq.scale[0], k, 256, &mut vis, Some(&pred)), &truth);
        }
        scan_us.sort_by(f64::total_cmp);
        us64.sort_by(f64::total_cmp);
        println!(
            "  {:>10} {:>8.1}% | {:>9.0}µs | {:>8.0}µs {:>10.4} {:>10.4}",
            allow.len(), share * 100.0, percentile(&scan_us, 0.5), percentile(&us64, 0.5),
            r64 / qids.len() as f64, r256 / qids.len() as f64
        );
    }
}
