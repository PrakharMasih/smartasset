"""Phase 3 speech evaluation manifest: the generated speech set, 40 real LibriSpeech utterances, and the timeline clip.
Runs inside the Phase 3 workspace (data only). Converts FLAC to 16 kHz mono WAV with the system afconvert.
Run: python3 -I make_asr_manifest.py"""
import json, os, subprocess, tarfile
from pathlib import Path

P3 = Path(os.environ.get("P3", Path.home() / "Library/Developer/SmartAsset/phase3"))
DATA = P3 / "data"
OUT = DATA / "asr"
(OUT / "libri").mkdir(parents=True, exist_ok=True)
items = []

# generated speech (exact reference text; Hindi and Hinglish included)
for s in json.load(open(DATA / "speech/speech.json")):
    lang = "hi" if s["group"] in ("hindi", "hinglish") else "en"
    items.append({"id": "tts-" + s["file"][:-4], "group": s["group"], "path": str(DATA / "speech" / s["file"]), "ref": s["text"], "language": lang, "seconds": s["seconds"]})

# the timeline clip: eight sentences with known start times
tl = json.load(open(DATA / "speech/timeline_en.json"))
items.append({"id": "timeline", "group": "timeline", "path": str(DATA / "speech/timeline_en.wav"), "ref": " ".join(x["text"] for x in tl["sentences"]),
              "language": "en", "seconds": tl["seconds"], "sentences": tl["sentences"]})

# real read speech: LibriSpeech test-clean, 2 utterances from each of 20 speakers
root = DATA / "librispeech/LibriSpeech/test-clean"
if not root.exists():
    with tarfile.open(DATA / "librispeech/test-clean.tar.gz") as t:
        t.extractall(DATA / "librispeech", filter="data")     # 'data' filter refuses paths that escape the folder
picked = 0
for spk in sorted(os.listdir(root))[:20]:
    done = 0
    for chap in sorted(os.listdir(root / spk)):
        trans = root / spk / chap / f"{spk}-{chap}.trans.txt"
        for line in trans.read_text().splitlines():
            uid, text = line.split(" ", 1)
            words = len(text.split())
            if not (14 <= words <= 55) or done >= 2:
                continue
            wav = OUT / "libri" / f"{uid}.wav"
            if not wav.exists():
                subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(root / spk / chap / f"{uid}.flac"), str(wav)], check=True)
            info = subprocess.run(["afinfo", str(wav)], capture_output=True, text=True).stdout
            secs = float([l for l in info.splitlines() if "estimated duration" in l][0].split()[2])
            items.append({"id": "libri-" + uid, "group": "librispeech (real speech)", "path": str(wav), "ref": text.lower(), "language": "en", "seconds": round(secs, 2)})
            done += 1
            picked += 1
        if done >= 2:
            break
(OUT / "manifest.json").write_text(json.dumps(items, indent=1, ensure_ascii=False))
print(len(items), "items;", round(sum(i["seconds"] for i in items)), "s of audio;", picked, "LibriSpeech utterances")
