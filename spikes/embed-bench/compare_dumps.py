#!/usr/bin/env python3
"""Compares two embedding dumps made from the same inputs (e.g. LiteRT GPU vs CPU).

    python3 -I compare_dumps.py <dump A> <dump B> [<dump A> <dump B> ...]

Reports, for queries and corpus separately, the cosine between A's and B's vector for the same input, and how well B's
top-10 over the corpus agrees with A's. Pure standard library (no numpy on the Command Line Tools Python).
Throwaway research code: not shipped.
"""
import array
import json
import math
import sys
from pathlib import Path


def load(path: Path, rows: int, dims: int):
    a = array.array("f")
    with open(path, "rb") as f:
        a.fromfile(f, rows * dims)
    if sys.byteorder != "little":
        a.byteswap()
    return [a[i * dims:(i + 1) * dims] for i in range(rows)]


def norm(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def stats(xs):
    xs = sorted(xs)
    return f"mean {sum(xs) / len(xs):.4f}  min {xs[0]:.4f}  p5 {xs[int(0.05 * (len(xs) - 1))]:.4f}  median {xs[len(xs) // 2]:.4f}"


def top(qv, corpus, k=10):
    scored = sorted(range(len(corpus)), key=lambda i: -dot(qv, corpus[i]))
    return scored[:k]


def compare(a_dir: Path, b_dir: Path):
    ma = json.loads((a_dir / "meta.json").read_text())
    mb = json.loads((b_dir / "meta.json").read_text())
    assert (ma["dims"], ma["queries"], ma["corpus"]) == (mb["dims"], mb["queries"], mb["corpus"]), "dumps differ in shape"
    d, nq, nc = ma["dims"], ma["queries"], ma["corpus"]
    qa = [norm(v) for v in load(a_dir / "queries.f32", nq, d)]
    qb = [norm(v) for v in load(b_dir / "queries.f32", nq, d)]
    ca = [norm(v) for v in load(a_dir / "corpus.f32", nc, d)]
    cb = [norm(v) for v in load(b_dir / "corpus.f32", nc, d)]
    print(f"== {a_dir.name}: {ma['runtime']}  vs  {mb['runtime']}  ({nq} queries, {nc} items, {d}d)")
    print("  query cosine :", stats([dot(x, y) for x, y in zip(qa, qb)]))
    print("  corpus cosine:", stats([dot(x, y) for x, y in zip(ca, cb)]))
    # Top-10 agreement: B's ranking of the corpus for each query against A's, each side using its own vectors.
    overlap, top1 = 0, 0
    for i in range(nq):
        ta, tb = top(qa[i], ca), top(qb[i], cb)
        overlap += len(set(ta) & set(tb))
        top1 += ta[0] == tb[0]
    print(f"  top-10 overlap {overlap / (10 * nq):.3f}   top-1 same {top1 / nq:.3f}")


def main():
    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2:
        sys.exit(__doc__)
    for a, b in zip(args[0::2], args[1::2]):
        compare(Path(a), Path(b))


if __name__ == "__main__":
    main()
