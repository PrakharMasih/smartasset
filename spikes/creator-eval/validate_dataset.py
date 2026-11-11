"""Validate a creator-media evaluation dataset (Phase 3, decision D3) and report its coverage.
Usage: python3 -I validate_dataset.py <dataset-dir>

<dataset-dir>/
  items.json     [{"id","path","kind":"video|image|audio","stratum","language","seconds","permission":{"basis","note"}}]
  queries.json   [{"id","text","feature","difficulty":"easy|medium|hard","language","relevant":[...],"hard_negatives":[...]}]
                 relevant entries: {"item": id} for whole-file hits, or {"item": id, "start": s, "end": s} for a moment.
A dataset passes only if: every file exists, every item has a recorded permission, every stratum has enough items, every
query has relevant items and hard negatives, every moment lies inside its file, and nothing refers to an unknown item.
Manual validation (decision 4 of 2026-11-07): every moment must carry a person's verdict "correct" in validation.json (written by review.py's page)
and a second reviewer must have independently checked at least 20 % of the queries' moments; "wrong" or "adjust" verdicts fail the dataset until
the annotation is fixed. Nothing is accepted on the annotator's word alone.
Exit status 0 on pass, 1 on any problem. It never reads or modifies media content."""
import json, sys
from collections import Counter, defaultdict
from pathlib import Path

STRATA = {  # stratum -> minimum items before the dataset may be used to select a model (D3)
    "screen_recording": 40, "tutorial_long_form": 25, "voiceover": 40, "noisy_recording": 40,
    "music": 30, "sound_effect": 40, "b_roll_or_footage": 40,
}
LANGUAGES = {"en", "hi", "hinglish"}   # recognised values
REQUIRED_LANGUAGES = {"en"}                # English first (owner, 2026-11-07); add "hi" and "hinglish" here when those phases open
FEATURES = {"S1", "S2", "S5", "S7", "S12", "C1", "C2", "A2"}
MIN_QUERIES_PER_FEATURE = 100
MIN_HARD_FRACTION = 0.30
MIN_LONG_SECONDS = 600           # at least some recordings long enough to make timestamp retrieval meaningful
PERMISSION_BASES = {"own work", "licensed to the owner for this use", "written consent of the people shown or heard"}

root = Path(sys.argv[1])
items = json.loads((root / "items.json").read_text())
queries = json.loads((root / "queries.json").read_text())
problems, warnings = [], []
ids = {}
for it in items:
    if it["id"] in ids: problems.append(f"duplicate item id {it['id']}")
    ids[it["id"]] = it
    if not (root / it["path"]).exists(): problems.append(f"{it['id']}: file missing ({it['path']})")
    if it.get("stratum") not in STRATA: problems.append(f"{it['id']}: unknown stratum {it.get('stratum')!r}")
    if it.get("language") not in LANGUAGES | {"none"}: problems.append(f"{it['id']}: language must be en, hi, hinglish or none")
    perm = it.get("permission") or {}
    if perm.get("basis") not in PERMISSION_BASES: problems.append(f"{it['id']}: no valid permission basis recorded")

by_stratum = Counter(i["stratum"] for i in items if i.get("stratum") in STRATA)
for s, need in STRATA.items():
    if by_stratum[s] < need: problems.append(f"stratum {s}: {by_stratum[s]} items, needs {need}")
by_lang = Counter(i.get("language") for i in items)
for lang in REQUIRED_LANGUAGES:
    if by_lang[lang] < 30: problems.append(f"language {lang}: {by_lang[lang]} items, needs 30")
for lang in LANGUAGES - REQUIRED_LANGUAGES:
    if by_lang[lang] < 30: warnings.append(f"language {lang}: {by_lang[lang]} items (a later language phase needs 30; not required now)")
if not any(i.get("seconds", 0) >= MIN_LONG_SECONDS for i in items): problems.append(f"no recording of {MIN_LONG_SECONDS} s or longer (timestamp retrieval needs long recordings)")

per_feature, hard, moments = Counter(), Counter(), 0
for q in queries:
    if q.get("feature") not in FEATURES: problems.append(f"{q['id']}: unknown feature {q.get('feature')!r}")
    if q.get("difficulty") not in ("easy", "medium", "hard"): problems.append(f"{q['id']}: difficulty must be easy, medium or hard")
    if not q.get("relevant"): problems.append(f"{q['id']}: no relevant item")
    if len(q.get("hard_negatives", [])) < 2: problems.append(f"{q['id']}: needs at least 2 hard negatives")
    per_feature[q.get("feature")] += 1
    hard[q.get("feature")] += q.get("difficulty") == "hard"
    for r in q.get("relevant", []):
        it = ids.get(r.get("item"))
        if not it: problems.append(f"{q['id']}: relevant item {r.get('item')!r} is not in items.json"); continue
        if "start" in r:
            moments += 1
            if not (0 <= r["start"] < r["end"] <= it.get("seconds", 0) + 0.5): problems.append(f"{q['id']}: moment {r['start']}-{r['end']} outside {it['id']} ({it.get('seconds')} s)")
    for h in q.get("hard_negatives", []):
        if h not in ids: problems.append(f"{q['id']}: hard negative {h!r} is not in items.json")
        if h in [r.get("item") for r in q.get("relevant", [])]: problems.append(f"{q['id']}: {h} is both relevant and a hard negative")
for f in FEATURES & set(per_feature):
    if per_feature[f] < MIN_QUERIES_PER_FEATURE: problems.append(f"feature {f}: {per_feature[f]} queries, needs {MIN_QUERIES_PER_FEATURE}")
    if hard[f] / per_feature[f] < MIN_HARD_FRACTION: problems.append(f"feature {f}: only {hard[f]/per_feature[f]:.0%} hard queries, needs {MIN_HARD_FRACTION:.0%}")
for f in FEATURES - set(per_feature): problems.append(f"feature {f}: no queries")
if moments < 50: problems.append(f"only {moments} moment annotations (S2 needs 50+ with start and end)")

# ---- manual validation of every annotated moment (by a person who played it), second reviewer on 20 % of queries
vpath = root / "validation.json"
verdicts = json.loads(vpath.read_text()) if vpath.exists() else []
by_key = defaultdict(list)
for v in verdicts: by_key[(v["query"], v["index"])].append(v)
moment_keys = [(q["id"], n) for q in queries for n, r in enumerate(q.get("relevant", [])) if "start" in r]
unvalidated = [k for k in moment_keys if not any(v["verdict"] == "correct" for v in by_key.get(k, []))]
bad = [k for k in moment_keys if any(v["verdict"] in ("wrong", "adjust") for v in by_key.get(k, []))]
if moment_keys:
    if unvalidated: problems.append(f"{len(unvalidated)} of {len(moment_keys)} moments have no person's 'correct' verdict (run review.py, check each, save validation.json)")
    if bad: problems.append(f"{len(bad)} moments were marked wrong or adjust: fix the annotation and review again")
    reviewers_by_key = {k: {v.get("reviewer") for v in vs if v.get("reviewer")} for k, vs in by_key.items()}
    double = sum(1 for k in moment_keys if len(reviewers_by_key.get(k, ())) >= 2)
    if double < 0.2 * len(moment_keys): problems.append(f"second reviewer covers {double} of {len(moment_keys)} moments; needs at least 20 %")
    print(f"manual validation: {len(moment_keys) - len(unvalidated)} of {len(moment_keys)} moments confirmed by a person; {double} checked by two reviewers")

print(f"items {len(items)}, queries {len(queries)}, moment annotations {moments}")
print("strata:", dict(by_stratum)); print("languages:", dict(by_lang)); print("queries per feature:", dict(per_feature))
for w in warnings: print("  note:", w)
print("PASS" if not problems else f"FAIL: {len(problems)} problems")
for p in problems[:40]: print("  -", p)
sys.exit(1 if problems else 0)
