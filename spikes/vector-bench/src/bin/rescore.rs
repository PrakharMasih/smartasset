//! Phase 4 accuracy spike: does re-scoring the cosine improve text -> image retrieval, without re-embedding anything?
//! Usage: rescore <dump-dir>   (same dump format as `eval`; one relevant image per query, captions grouped by image)
//!
//! Honest split: the "bank" used to estimate how hub-like each picture is comes ONLY from the captions of the first half
//! of the pictures; every number reported is on the captions of the second half (whose text the bank never saw), searched
//! against the whole corpus.
//!
//! Variants:
//!   raw          cosine (what the app does today)
//!   mean-q b     cos(q,i) - b * cos(mu_q, i)            mu_q = mean of the bank's query vectors (one shipped vector)
//!   center-i     cos(q, normalise(i - mu_i))            mu_i = mean of the corpus' picture vectors
//!   csls k b     cos(q,i) - b * r_i                     r_i = mean of picture i's k best cosines against the bank
use std::fs;
use std::path::Path;

fn read_f32(path: &Path) -> Vec<f32> {
    let b = fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

fn first_index_per_query(s: &str) -> Vec<usize> {
    // relevance.json: [[i],[i],...] with exactly one picture per caption in the COCO dumps.
    s.split(']').filter_map(|p| p.trim_start_matches([',', '[', ' ']).split(',').next()?.trim().parse().ok()).collect()
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn normalise(v: &mut [f32]) {
    let n = dot(v, v).sqrt();
    if n > 0.0 {
        v.iter_mut().for_each(|x| *x /= n);
    }
}

struct Scores {
    hit1: f64,
    hit5: f64,
    hit10: f64,
    mrr10: f64,
}

/// Rank of the right picture for each test query under `score(q_index, raw_cos_row) -> adjusted row`.
fn evaluate(test: &[usize], rel: &[usize], sims: &[Vec<f32>], adjust: &dyn Fn(usize, f32) -> f32) -> Scores {
    let (mut h1, mut h5, mut h10, mut mrr) = (0usize, 0usize, 0usize, 0.0f64);
    for (t, &q) in test.iter().enumerate() {
        let row = &sims[t];
        let target = rel[q];
        let s_target = adjust(target, row[target]);
        let better = row.iter().enumerate().filter(|&(i, &c)| i != target && adjust(i, c) > s_target).count();
        let rank = better + 1;
        h1 += usize::from(rank <= 1);
        h5 += usize::from(rank <= 5);
        h10 += usize::from(rank <= 10);
        if rank <= 10 {
            mrr += 1.0 / rank as f64;
        }
    }
    let n = test.len() as f64;
    Scores { hit1: h1 as f64 / n, hit5: h5 as f64 / n, hit10: h10 as f64 / n, mrr10: mrr / n }
}

fn print(name: &str, s: &Scores) {
    println!("{name:<28} hit@1 {:.3}  hit@5 {:.3}  hit@10 {:.3}  MRR@10 {:.3}", s.hit1, s.hit5, s.hit10, s.mrr10);
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: rescore <dump-dir>");
    let dir = Path::new(&dir);
    let dims = 768;
    let corpus = read_f32(&dir.join("corpus.f32"));
    let queries = read_f32(&dir.join("queries.f32"));
    let rel = first_index_per_query(&fs::read_to_string(dir.join("relevance.json")).expect("relevance"));
    let m = corpus.len() / dims;
    let n = queries.len() / dims;
    assert_eq!(rel.len(), n, "one relevant picture per query");
    let pic = |i: usize| &corpus[i * dims..(i + 1) * dims];
    let qv = |q: usize| &queries[q * dims..(q + 1) * dims];

    let half = m / 2;
    let bank: Vec<usize> = (0..n).filter(|&q| rel[q] < half).collect();
    let test: Vec<usize> = (0..n).filter(|&q| rel[q] >= half).collect();
    println!("{} pictures, bank {} captions (pictures < {half}), test {} captions\n", m, bank.len(), test.len());

    // Raw cosines of every test query against every picture.
    let sims: Vec<Vec<f32>> = test.iter().map(|&q| (0..m).map(|i| dot(qv(q), pic(i))).collect()).collect();
    print("raw cosine", &evaluate(&test, &rel, &sims, &|_, c| c));

    // Earlier variants (mean-question subtraction, picture centring, bank-free hub correction from the pictures' own
    // neighbours) were measured on the 70-token dump and rejected (docs/research/phase4-semantic-search.md, "Accuracy").

    // csls with a personal history: the bank is the n questions a user has asked so far (here: n captions of the tuning
    // half). What weight b is right while the history is still small?
    for bank_size in [100usize, 300, 1000, 2000, 5000, bank.len()] {
        let step = (bank.len() / bank_size).max(1);
        let sub: Vec<usize> = bank.iter().step_by(step).copied().take(bank_size).collect();
        for k in [5usize, 10] {
            let r: Vec<f32> = (0..m)
                .map(|i| {
                    let mut c: Vec<f32> = sub.iter().map(|&q| dot(qv(q), pic(i))).collect();
                    c.sort_by(|a, b| b.total_cmp(a));
                    c.iter().take(k).sum::<f32>() / k.min(c.len()) as f32
                })
                .collect();
            for b in [0.25f32, 0.5, 0.75] {
                print(&format!("csls bank={} k={k} b={b}", sub.len()), &evaluate(&test, &rel, &sims, &|i, c| c - b * r[i]));
            }
        }
    }

    // Worst case for a personal history: the bank already holds questions about the very photos being searched for (here
    // the other four captions of each test photo, plus the tuning half), as when someone searches for the same file again.
    if std::env::var("SELF").is_ok() {
        let own: Vec<usize> = (0..n).filter(|&q| !test.contains(&q) || q % 5 != 0).collect();
        let evaluated: Vec<usize> = test.iter().copied().filter(|q| q % 5 == 0).collect();
        let ev_sims: Vec<Vec<f32>> = test.iter().zip(&sims).filter(|(q, _)| *q % 5 == 0).map(|(_, r)| r.clone()).collect();
        print("raw (first caption of test photos)", &evaluate(&evaluated, &rel, &ev_sims, &|_, c| c));
        for bank_size in [500usize, 2000, own.len()] {
            // Every test photo's other captions are always in; the tuning half fills the rest.
            let mut sub: Vec<usize> = own.iter().copied().filter(|&q| rel[q] >= half).collect();
            let fill: Vec<usize> = own.iter().copied().filter(|&q| rel[q] < half).collect();
            let extra = bank_size.saturating_sub(sub.len()).min(fill.len());
            sub.extend(fill.iter().step_by((fill.len() / extra.max(1)).max(1)).take(extra));
            let r: Vec<f32> = (0..m)
                .map(|i| {
                    let mut c: Vec<f32> = sub.iter().map(|&q| dot(qv(q), pic(i))).collect();
                    c.sort_by(|a, b| b.total_cmp(a));
                    c.iter().take(5).sum::<f32>() / 5.0
                })
                .collect();
            for b in [0.25f32, 0.5] {
                print(&format!("self-inclusive bank={} b={b}", sub.len()), &evaluate(&evaluated, &rel, &ev_sims, &|i, c| c - b * r[i]));
            }
        }
        return;
    }

    // Pseudo-relevance feedback: move the question toward its own top-m pictures, then search again (every 5th test caption).
    let few: Vec<usize> = test.iter().step_by(5).copied().collect();
    let few_sims: Vec<Vec<f32>> = test.iter().step_by(5).zip(sims.iter().step_by(5)).map(|(_, row)| row.clone()).collect();
    print("raw (every 5th caption)", &evaluate(&few, &rel, &few_sims, &|_, c| c));
    for top_m in [3usize, 10] {
        for alpha in [0.2f32, 0.5] {
            let moved: Vec<Vec<f32>> = few
                .iter()
                .zip(&few_sims)
                .map(|(&q, row)| {
                    let mut order: Vec<usize> = (0..m).collect();
                    order.sort_by(|&a, &b| row[b].total_cmp(&row[a]));
                    let mut v = qv(q).to_vec();
                    for &i in order.iter().take(top_m) {
                        v.iter_mut().zip(pic(i)).for_each(|(a, b)| *a += alpha * b / top_m as f32);
                    }
                    normalise(&mut v);
                    (0..m).map(|i| dot(&v, pic(i))).collect()
                })
                .collect();
            print(&format!("prf m={top_m} a={alpha}"), &evaluate(&few, &rel, &moved, &|_, c| c));
        }
    }
}
