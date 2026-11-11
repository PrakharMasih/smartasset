"""One table over every transcription result file, measured the same way for every engine.

Usage (inside the sandbox): python3 -I compare_asr.py <result.json> [...]

Speed is "whole file in, text out": for whisper.cpp the per-file wall time minus that process's model load (the process also reads the
audio and computes the mel spectrogram), for WhisperKit the `transcribe` call. Both exclude model load, which is reported separately.
WER and CER use the same normaliser as score_asr.py. Throwaway research code: not shipped."""
import json, statistics, sys
sys.argv, files = sys.argv[:1], sys.argv[1:]          # score_asr runs its scoring loop over argv at import time: give it nothing
import score_asr as sc

GROUPS = ["english", "indian_english", "noisy_english", "librispeech (real speech)", "hindi", "hinglish"]
SHORT = {"english": "en", "indian_english": "en-IN", "noisy_english": "noisy", "librispeech (real speech)": "LibriSpeech", "hindi": "hi", "hinglish": "hi-en"}

def per_group(res):
    out, load = {}, res.get("load_ms") or []
    for i, it in enumerate(res["items"]):
        m = sc.manifest[it["id"]]
        if m["group"] == "timeline":
            continue
        g = out.setdefault(m["group"], {"we": 0, "w": 0, "ce": 0, "c": 0, "ms": 0.0, "s": 0.0})
        ref, hyp = sc.norm(m["ref"]), sc.norm(it["hyp"])
        g["we"] += sc.edits(ref, hyp); g["w"] += len(ref)
        g["ce"] += sc.edits(list("".join(ref)), list("".join(hyp))); g["c"] += len("".join(ref))
        if "wall_ms" in it and i < len(load):
            g["ms"] += it["wall_ms"] - load[i]               # whisper.cpp: process wall time without the model load
        else:
            g["ms"] += it["infer_ms"]                         # WhisperKit: the transcribe call
        g["s"] += it["audio_s"]
    return out

rows = []
for path in files:
    res = json.load(open(path))
    g = per_group(res)
    tl = next((i for i in res["items"] if i["id"] == "timeline"), None)
    errs, total = sc.timeline_errors(tl) if tl and tl.get("words") else ([], 8)
    det = res.get("language_detection")
    rows.append((res["engine"].split(" (")[0], res["model"], g, errs, total, det))

print("Word error rate (lower is better); each cell is one group of 8 utterances, LibriSpeech 40 (real speech)")
print(f"  {'engine / model':<44}" + "".join(f"{SHORT[k]:>12}" for k in GROUPS))
for eng, model, g, *_ in rows:
    print(f"  {eng + ' ' + model:<44}" + "".join(f"{g[k]['we'] / max(1, g[k]['w']):>12.3f}" if k in g else f"{'-':>12}" for k in GROUPS))
print("\nCharacter error rate on Hindi and Hinglish")
for eng, model, g, *_ in rows:
    print(f"  {eng + ' ' + model:<44}" + "".join(f"{g[k]['ce'] / max(1, g[k]['c']):>12.3f}" for k in ("hindi", "hinglish")))
print("\nReal-time factor, whole file in / text out, model load excluded (lower is faster; 0.05 = 20x faster than real time)")
print(f"  {'engine / model':<44}" + "".join(f"{SHORT[k]:>12}" for k in ("librispeech (real speech)", "english", "hindi", "hinglish")))
for eng, model, g, *_ in rows:
    print(f"  {eng + ' ' + model:<44}" + "".join(f"{g[k]['ms'] / 1000 / max(1e-9, g[k]['s']):>12.3f}" for k in ("librispeech (real speech)", "english", "hindi", "hinglish")))
print("\nSentence-start timestamps on the 59.5 s timeline clip (8 sentences)")
for eng, model, g, errs, total, det in rows:
    if errs:
        p90 = errs[min(len(errs) - 1, int(len(errs) * 0.9))]
        print(f"  {eng + ' ' + model:<44} located {len(errs)}/{total}; median error {statistics.median(errs):.2f} s, p90 {p90:.2f} s, max {errs[-1]:.2f} s")
    else:
        print(f"  {eng + ' ' + model:<44} no word times produced")
