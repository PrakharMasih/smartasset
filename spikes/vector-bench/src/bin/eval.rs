//! Retrieval evaluator for embedding dumps (Phase 3). Usage: eval <dump-dir> [<dump-dir> ...]
//!
//! A dump directory holds (all little-endian, vectors already L2-normalised at the native dimension):
//!   meta.json        {"dims": 768, "queries": N, "corpus": M, "task": "text -> image", "runtime": "..."}
//!   queries.f32      N x dims
//!   corpus.f32       M x dims
//!   relevance.json   [[corpus indices relevant to query 0], [..query 1], ...]
//!   groups.json      (optional) one label per query ("hindi", "dog", ...): results are broken down per group
//!   queries.json     (optional) the text of each query, to list the hardest ones
//!
//! For every dimension (768, 512, 256, 128 by truncating and re-normalising) and every storage format (f32, f16 as it
//! would sit in SQLite, int8 as it would sit in an index) it reports hit@1/5/10, MRR@10 and mean precision@10.
//! The same tool scores the owner's real media later: only the dump changes.

use std::fs;
use std::path::Path;

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
                c.push(num.parse().unwrap());
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

/// `["a","b"]` -> strings (handles \" and \\ escapes; enough for the dumps we write).
fn parse_strings(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let (mut inside, mut esc) = (false, false);
    for ch in s.chars() {
        if inside {
            if esc {
                cur.push(match ch { 'n' => '\n', 't' => '\t', c => c });
                esc = false;
            } else if ch == '\\' {
                esc = true;
            } else if ch == '"' {
                out.push(std::mem::take(&mut cur));
                inside = false;
            } else {
                cur.push(ch);
            }
        } else if ch == '"' {
            inside = true;
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

fn f16_round(x: f32) -> f32 {
    // Round to 10 mantissa bits, as binary16 does for values in the unit-vector range (|x| < 2, no subnormals matter).
    if x == 0.0 || !x.is_finite() {
        return x;
    }
    let b = x.to_bits();
    let rounded = (b.wrapping_add(0x1000)) & !0x1FFF;
    f32::from_bits(rounded)
}

fn int8_roundtrip(v: &[f32], dims: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(v.len());
    for row in v.chunks_exact(dims) {
        let max = row.iter().fold(0f32, |m, x| m.max(x.abs())).max(1e-9);
        let s = max / 127.0;
        out.extend(row.iter().map(|x| (x / s).round().clamp(-127.0, 127.0) * s));
    }
    out
}

struct Scores {
    hit1: f64,
    hit5: f64,
    hit10: f64,
    mrr: f64,
    p10: f64,
}

/// Rank (1-based) of the first relevant item for every query; `usize::MAX` when none is relevant or found.
fn ranks(queries: &[f32], corpus: &[f32], dims: usize, relevant: &[Vec<usize>]) -> Vec<usize> {
    let n_c = corpus.len() / dims;
    queries
        .chunks_exact(dims)
        .enumerate()
        .map(|(qi, q)| {
            let rel = &relevant[qi];
            if rel.is_empty() {
                return usize::MAX;
            }
            let mut scored: Vec<(f32, usize)> =
                (0..n_c).map(|i| (q.iter().zip(&corpus[i * dims..(i + 1) * dims]).map(|(a, b)| a * b).sum::<f32>(), i)).collect();
            scored.sort_by(|a, b| b.0.total_cmp(&a.0));
            scored.iter().position(|(_, i)| rel.contains(i)).map_or(usize::MAX, |r| r + 1)
        })
        .collect()
}

fn evaluate_subset(queries: &[f32], corpus: &[f32], dims: usize, relevant: &[Vec<usize>], only: &[usize]) -> Scores {
    let sub_q: Vec<f32> = only.iter().flat_map(|&i| queries[i * dims..(i + 1) * dims].iter().copied()).collect();
    let sub_r: Vec<Vec<usize>> = only.iter().map(|&i| relevant[i].clone()).collect();
    evaluate(&sub_q, corpus, dims, &sub_r)
}

fn evaluate(queries: &[f32], corpus: &[f32], dims: usize, relevant: &[Vec<usize>]) -> Scores {
    let n_c = corpus.len() / dims;
    let (mut h1, mut h5, mut h10, mut mrr, mut p10, mut counted) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    for (qi, q) in queries.chunks_exact(dims).enumerate() {
        let rel = &relevant[qi];
        if rel.is_empty() {
            continue;
        }
        let mut scored: Vec<(f32, usize)> =
            (0..n_c).map(|i| (q.iter().zip(&corpus[i * dims..(i + 1) * dims]).map(|(a, b)| a * b).sum::<f32>(), i)).collect();
        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        let first = scored.iter().position(|(_, i)| rel.contains(i));
        counted += 1.0;
        if let Some(r) = first {
            if r < 1 {
                h1 += 1.0;
            }
            if r < 5 {
                h5 += 1.0;
            }
            if r < 10 {
                h10 += 1.0;
                mrr += 1.0 / (r as f64 + 1.0);
            }
        }
        p10 += scored.iter().take(10).filter(|(_, i)| rel.contains(i)).count() as f64 / 10.0_f64.min(rel.len() as f64);
    }
    Scores { hit1: h1 / counted, hit5: h5 / counted, hit10: h10 / counted, mrr: mrr / counted, p10: p10 / counted }
}

fn main() {
    let dirs: Vec<String> = std::env::args().skip(1).collect();
    if dirs.is_empty() {
        eprintln!("usage: eval <dump-dir> [<dump-dir> ...]");
        std::process::exit(2);
    }
    for dir in dirs {
        let d = Path::new(&dir);
        let meta = fs::read_to_string(d.join("meta.json")).expect("meta.json");
        let dims: usize = json_field(&meta, "dims").and_then(|s| s.parse().ok()).expect("dims");
        let q = read_f32(&d.join("queries.f32"));
        let c = read_f32(&d.join("corpus.f32"));
        let rel = parse_relevance(&fs::read_to_string(d.join("relevance.json")).expect("relevance.json"));
        assert_eq!(q.len() / dims, rel.len(), "one relevance list per query");
        let groups: Vec<String> = fs::read_to_string(d.join("groups.json")).map(|t| parse_strings(&t)).unwrap_or_default();
        let texts: Vec<String> = fs::read_to_string(d.join("queries.json")).map(|t| parse_strings(&t)).unwrap_or_default();
        println!(
            "\n== {} | {} | {} queries, {} items, native {dims}d",
            json_field(&meta, "task").unwrap_or_default(),
            json_field(&meta, "runtime").unwrap_or_default(),
            q.len() / dims,
            c.len() / dims
        );
        println!("  {:>5} {:>5} | {:>7} {:>7} {:>7} {:>7} {:>7}", "dims", "store", "hit@1", "hit@5", "hit@10", "MRR@10", "P@10");
        for to in [768usize, 512, 256, 128].into_iter().filter(|&t| t <= dims) {
            let qt = truncate(&q, dims, to);
            let ct = truncate(&c, dims, to);
            for (name, corpus) in [("f32", ct.clone()), ("f16", ct.iter().map(|&x| f16_round(x)).collect()), ("int8", int8_roundtrip(&ct, to))] {
                let s = evaluate(&qt, &corpus, to, &rel);
                println!("  {to:>5} {name:>5} | {:>7.3} {:>7.3} {:>7.3} {:>7.3} {:>7.3}", s.hit1, s.hit5, s.hit10, s.mrr, s.p10);
            }
        }
        // Per group, and the hardest queries, at 768 and 512 dimensions in f32 (aggregate scores hide failures).
        for to in [768usize, 512].into_iter().filter(|&t| t <= dims) {
            let qt = truncate(&q, dims, to);
            let ct = truncate(&c, dims, to);
            if groups.len() == rel.len() {
                println!("  per group at {to}d f32:   {:<22} {:>5} | {:>7} {:>7} {:>7} {:>7}", "group", "n", "hit@1", "hit@10", "MRR@10", "P@10");
                let mut names: Vec<&String> = groups.iter().collect();
                names.sort();
                names.dedup();
                for g in names {
                    let only: Vec<usize> = (0..rel.len()).filter(|&i| &groups[i] == g).collect();
                    let s = evaluate_subset(&qt, &ct, to, &rel, &only);
                    println!("  {:<33} {:<22} {:>5} | {:>7.3} {:>7.3} {:>7.3} {:>7.3}", "", g, only.len(), s.hit1, s.hit10, s.mrr, s.p10);
                }
            }
            let rk = ranks(&qt, &ct, to, &rel);
            let found = |lo: usize, hi: usize| rk.iter().filter(|&&r| r >= lo && r <= hi).count();
            println!(
                "  rank of first relevant at {to}d: 1 -> {} | 2-5 -> {} | 6-10 -> {} | 11-50 -> {} | beyond 50 or not found -> {}",
                found(1, 1), found(2, 5), found(6, 10), found(11, 50), rk.iter().filter(|&&r| r > 50).count()
            );
            if to == 768 || dims < 768 {
                let mut worst: Vec<(usize, usize)> = rk.iter().copied().enumerate().filter(|&(_, r)| r != usize::MAX).collect();
                worst.sort_by_key(|&(_, r)| std::cmp::Reverse(r));
                for &(i, r) in worst.iter().take(5) {
                    let g = groups.get(i).map_or("", String::as_str);
                    let t = texts.get(i).map_or("", String::as_str);
                    println!("    hard: rank {r:>4} [{g}] {}", t.chars().take(90).collect::<String>());
                }
            }
        }
    }
}
