"""Real Hindi speech for the transcription comparison: 40 utterances sampled (fixed seed) from the FLEURS Hindi test split (Google, CC BY 4.0),
read aloud by many different speakers. Extracts only the chosen members by exact name into a fresh folder, never the whole archive.
Writes data/asr/manifest_hindi.json (select it with ASR_MANIFEST=manifest_hindi.json). Run inside the sandbox: python3 -I make_fleurs_manifest.py"""
import csv, json, os, random, tarfile
from pathlib import Path

P3 = Path(os.environ["P3"])
base = P3 / "data/fleurs/data/hi_in"
rows = [r for r in csv.reader(open(base / "test.tsv", encoding="utf-8"), delimiter="\t") if len(r) >= 7]
random.Random(20261108).shuffle(rows)
chosen = rows[:40]
out = P3 / "data/asr/fleurs_hi"; out.mkdir(parents=True, exist_ok=True)
wanted = {f"test/{r[1]}": r for r in chosen}
items = []
with tarfile.open(base / "audio/test.tar.gz") as t:
    for m in t.getmembers():
        r = wanted.get(m.name)
        if not r or not m.isfile() or ".." in m.name: continue
        (out / r[1]).write_bytes(t.extractfile(m).read())
        items.append({"id": "fleurs-" + r[0], "group": "hindi (real speech, FLEURS)", "path": str(out / r[1]), "ref": r[2], "language": "hi",
                      "seconds": round(int(r[5]) / 16000, 2), "gender": r[6]})
json.dump(items, open(P3 / "data/asr/manifest_hindi.json", "w"), indent=1, ensure_ascii=False)
g = {x: sum(1 for i in items if i["gender"] == x) for x in {i["gender"] for i in items}}
print(len(items), "utterances,", round(sum(i["seconds"] for i in items)), "s,", g)
