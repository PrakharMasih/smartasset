"""Run whisper.cpp's whisper-cli over the manifest, one process per item, and collect transcripts, word times, the
inference time whisper.cpp reports (encode + decode, excluding model load), and the process's peak memory.
Usage (inside the sandbox): python3 -I run_whispercpp.py <ggml-model> <label> [--quick]"""
import json, os, re, subprocess, sys, time
from pathlib import Path

P3 = Path(os.environ["P3"])
model, label = sys.argv[1], sys.argv[2]
quick = "--quick" in sys.argv
cli = P3 / "work/whispercpp-build/bin/whisper-cli"
items = json.load(open(P3 / "data/asr" / os.environ.get("ASR_MANIFEST", "manifest.json")))
if quick:
    items = [i for i in items if i["id"] in ("tts-en0", "tts-hi0", "tts-hg0", "timeline")]
out = {"engine": "whisper.cpp v1.9.5 (Metal)", "model": label, "model_file": os.path.basename(model), "items": [], "load_ms": [], "peak_rss_mb": []}
work = P3 / "results/asr/_wcpp"
work.mkdir(parents=True, exist_ok=True)

def ms(pattern, text):
    m = re.search(pattern, text)
    return float(m.group(1)) if m else None

def segments(path):
    """Entries (text, start, end in seconds) from a whisper.cpp JSON file. With --dtw the start is the DTW-aligned time of the entry's first token
    when whisper.cpp produced one (t_dtw, in 10 ms units; -1 means not computed), otherwise the segment offset."""
    if not Path(path).exists():
        return []
    out = []
    for seg in json.load(open(path)).get("transcription", []):
        text = seg["text"].strip()
        if not text:
            continue
        start = seg["offsets"]["from"] / 1000
        dtw = [t.get("t_dtw", -1) for t in seg.get("tokens", []) if t.get("t_dtw", -1) not in (-1, None) and not t.get("text", "").startswith("[_")]
        if dtw:
            start = dtw[0] / 100
        out.append({"w": text, "s": start, "e": seg["offsets"]["to"] / 1000})
    return out

for it in items:
    base = work / it["id"]
    # Pass 1 produces the transcript and the speed figures. Not -np: that also hides the timing lines parsed below.
    # Not -ml 1 / -sow either: for scripts written without spaces (Devanagari) that splits one word into token pieces,
    # and joining the pieces with spaces would inflate the Hindi and Hinglish error rates by a harness artefact.
    cmd = ["/usr/bin/time", "-l", str(cli), "-m", model, "-f", it["path"], "-l", it["language"], "-ojf", "-of", str(base), "-nt", *os.environ.get("WCPP_EXTRA", "").split()]   # WCPP_EXTRA: extra whisper-cli flags, e.g. "--max-context 0"
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    wall = (time.time() - t0) * 1000
    err = r.stderr
    segs = segments(str(base) + ".json")
    load = ms(r"load time =\s+([\d.]+) ms", err)
    infer = sum(ms(p, err) or 0 for p in (r"encode time =\s+([\d.]+) ms", r"decode time =\s+([\d.]+) ms", r"batchd time =\s+([\d.]+) ms", r"prompt time =\s+([\d.]+) ms"))
    rss = ms(r"(\d+)\s+maximum resident set size", err)
    if load is not None: out["load_ms"].append(load)
    if rss: out["peak_rss_mb"].append(rss / 1048576)
    words = []
    if it["id"].startswith("timeline"):
        # Pass 2, the timeline clip only: one entry per word so sentence starts can be located (English has spaces, so this is safe).
        wbase = work / (it["id"] + "-words")
        subprocess.run([str(cli), "-m", model, "-f", it["path"], "-l", it["language"], "-ojf", "-of", str(wbase), "-ml", "1", "-sow", "-nt", *os.environ.get("WCPP_EXTRA", "").split()],
                       capture_output=True, text=True)
        words = segments(str(wbase) + ".json")
    out["items"].append({"id": it["id"], "hyp": " ".join(x["w"] for x in segs), "infer_ms": infer, "wall_ms": wall, "audio_s": it["seconds"],
                         "segments": segs, "words": words})
    print(it["id"], round(infer), "ms", flush=True)
(P3 / f"results/asr/whispercpp-{label}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print("written", label)
