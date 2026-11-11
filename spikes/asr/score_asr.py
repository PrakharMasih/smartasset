"""Score transcription results against the manifest: WER, CER, speed (real-time factor), and timestamp error on the
timeline clip. Usage: python3 -I score_asr.py <result.json> [...]   (results are written by the engine harnesses)"""
import difflib, json, os, re, statistics, sys, unicodedata
from pathlib import Path

P3 = Path(os.environ.get("P3", Path.home() / "Library/Developer/SmartAsset/phase3"))
manifest = {i["id"]: i for i in json.load(open(P3 / "data/asr" / os.environ.get("ASR_MANIFEST", "manifest.json")))}

def norm(s):
    """Lower-case, drop punctuation, split into words. Letters, combining marks (Devanagari vowel signs are marks) and
    digits are kept: a plain regex \\w drops the marks and would cut every Hindi word at its vowel signs."""
    s = unicodedata.normalize("NFC", s).lower().replace("।", " ").replace("’", "'")
    s = s.replace("\u200c", "").replace("\u200d", "")           # zero-width (non-)joiners are not word breaks
    s = "".join(c if (unicodedata.category(c)[0] in "LMN" or c == "'") else " " for c in s)
    return s.split()

def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def is_devanagari(w): return any("ऀ" <= c <= "ॿ" for c in w)

def timeline_errors(tl):
    """Sorted absolute errors (s) of the sentence starts that could be matched, and the number of sentences."""
    sentences = manifest[tl["id"]]["sentences"]
    ref_words, owner = [], []
    for si, s in enumerate(sentences):
        for k, w in enumerate(norm(s["text"])):
            ref_words.append(w); owner.append((si, k))
    hyp_words = [(norm(w["w"]), w["s"]) for w in tl["words"]]
    hyp_flat = [(x, t) for ws, t in hyp_words for x in ws]
    sm = difflib.SequenceMatcher(a=ref_words, b=[x for x, _ in hyp_flat], autojunk=False)
    first = {}
    for a, b, size in [(blk.a, blk.b, blk.size) for blk in sm.get_matching_blocks()]:
        for d in range(size):
            si, k = owner[a + d]
            if k == 0 or (si not in first and k <= 2):      # the first word, or the next if the first was missed
                first.setdefault(si, hyp_flat[b + d][1])
    return sorted(abs(first[si] - s["speech_start"]) for si, s in enumerate(sentences) if si in first), len(sentences)

for path in sys.argv[1:]:
    res = json.load(open(path))
    groups = {}
    for it in res["items"]:
        m = manifest[it["id"]]
        if m["group"] == "timeline":
            continue
        ref, hyp = norm(m["ref"]), norm(it["hyp"])
        g = groups.setdefault(m["group"], {"n": 0, "w_err": 0, "w": 0, "c_err": 0, "c": 0, "ms": 0.0, "s": 0.0, "roman_for_devanagari": 0, "worst": []})
        we = edits(ref, hyp)
        ce = edits(list("".join(ref)), list("".join(hyp)))
        g["n"] += 1; g["w_err"] += we; g["w"] += len(ref); g["c_err"] += ce; g["c"] += len("".join(ref))
        g["ms"] += it["infer_ms"]; g["s"] += it["audio_s"]
        if any(is_devanagari(w) for w in ref) and not any(is_devanagari(w) for w in hyp): g["roman_for_devanagari"] += 1
        g["worst"].append((we / max(1, len(ref)), it["id"], " ".join(hyp)[:70]))
    print(f"\n== {res['engine']} | {res['model']} | load {statistics.mean(res['load_ms']) if res.get('load_ms') else res.get('load_ms_single', 0):.0f} ms | peak memory {max(res.get('peak_rss_mb') or [res.get('footprint_peak_mb', 0)]):.0f} MB")
    print(f"  {'group':<28}{'n':>3} {'WER':>7} {'CER':>7} {'RTF':>7}  notes")
    for name, g in sorted(groups.items()):
        note = f"{g['roman_for_devanagari']} of {g['n']} answered in Roman script" if g["roman_for_devanagari"] else ""
        print(f"  {name:<28}{g['n']:>3} {g['w_err']/max(1,g['w']):>7.3f} {g['c_err']/max(1,g['c']):>7.3f} {g['ms']/1000/max(1e-9,g['s']):>7.3f}  {note}")
        for w, i, h in sorted(g["worst"], reverse=True)[:1]:
            if w > 0.25: print(f"      worst {i}: WER {w:.2f}  “{h}”")
    # timestamps: where does each sentence of the timeline start, against the known start?
    for tl in [it for it in res["items"] if it["id"].startswith("timeline") and it.get("words")]:
        errs, total = timeline_errors(tl)
        if errs:
            print(f"  {tl['id']}: {len(errs)} of {total} sentence starts located; error median {statistics.median(errs):.2f} s, "
                  f"p90 {errs[min(len(errs)-1, int(len(errs)*0.9))]:.2f} s, max {errs[-1]:.2f} s")
        else:
            print(f"  {tl['id']}: no sentence start could be matched")
    det = res.get("language_detection")
    if det:
        ok = sum(1 for d in det if d["detected"] == d["expected"])
        wrong = ", ".join(f"{d['id']}->{d['detected'] or '?'}" for d in det if d["detected"] != d["expected"])
        print(f"  language detection on Hindi + Hinglish clips (no language given): {ok} of {len(det)} detected as {det[0]['expected']}" + (f"; others: {wrong}" if wrong else ""))
