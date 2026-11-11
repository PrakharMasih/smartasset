"""Builds one long recording of real speech with a known start for every sentence: the 40 LibriSpeech utterances of the manifest joined by
silences of 1.0-2.5 s (fixed seed). Ground truth for each sentence is where its speech starts in the joined file: the position it was placed at plus the
silence at the head of that utterance, found with a simple level threshold (so the truth is good to about +-0.05 s: errors smaller than that mean nothing).
Writes data/asr/long/timeline_long.wav and data/asr/manifest_long.json (select it with ASR_MANIFEST=manifest_long.json).
Run inside the sandbox: python3 -I make_long_timeline.py"""
import array, json, math, os, random, wave
from pathlib import Path

P3 = Path(os.environ["P3"])
src = [i for i in json.load(open(P3 / "data/asr/manifest.json")) if i["id"].startswith("libri-")]
out_dir = P3 / "data/asr/long"; out_dir.mkdir(parents=True, exist_ok=True)
RATE = 16000
rng = random.Random(20261108)

def head_silence(samples):
    win = RATE // 100
    rms = [math.sqrt(sum(x * x for x in samples[i:i + win]) / win) for i in range(0, min(len(samples), RATE * 3) - win, win)]
    floor = sorted(rms)[max(0, len(rms) // 10)]
    for k, r in enumerate(rms):
        if r > 4 * floor + 100: return k * 0.01
    return 0.0

def read_pcm16(path):
    """16-bit mono samples from a RIFF/WAVE file. Reads the chunks itself: afconvert writes the 'extensible' header, which Python's wave module rejects."""
    b = open(path, "rb").read()
    assert b[:4] == b"RIFF" and b[8:12] == b"WAVE"
    pos, fmt = 12, None
    while pos + 8 <= len(b):
        cid, size = b[pos:pos + 4], int.from_bytes(b[pos + 4:pos + 8], "little")
        body = b[pos + 8:pos + 8 + size]
        if cid == b"fmt ": fmt = (int.from_bytes(body[2:4], "little"), int.from_bytes(body[4:8], "little"), int.from_bytes(body[14:16], "little"))
        if cid == b"data":
            assert fmt == (1, RATE, 16), f"expected 1 channel, {RATE} Hz, 16 bit; got {fmt}"
            a = array.array("h"); a.frombytes(body[:len(body) // 2 * 2]); return a
        pos += 8 + size + (size & 1)
    raise ValueError("no data chunk")

pcm, sentences, pos = array.array("h"), [], 0.0
for it in src:
    s = read_pcm16(it["path"])
    gap = rng.uniform(1.0, 2.5)
    pcm.extend(array.array("h", [0]) * int(gap * RATE)); pos += gap
    sentences.append({"text": it["ref"], "start": round(pos, 3), "speech_start": round(pos + head_silence(s), 3)})
    pcm.extend(s); pos += len(s) / RATE
with wave.open(str(out_dir / "timeline_long.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(pcm.tobytes())
item = {"id": "timeline-long", "group": "longform (real speech)", "path": str(out_dir / "timeline_long.wav"), "ref": " ".join(s["text"] for s in sentences),
        "language": "en", "seconds": round(pos, 2), "sentences": sentences}
json.dump([item], open(P3 / "data/asr/manifest_long.json", "w"), indent=1, ensure_ascii=False)
print(f"{len(sentences)} sentences, {pos:.0f} s ({pos / 60:.1f} min)")
