"""Phase 3 proxy set: pick 500 of the 5,000 COCO test images (fixed seed) and their human captions. Reads the CSV and
extracts only the 500 chosen JPEGs from the zip, by name, into a fresh folder (zip entries are checked for path safety).
Run: python3 -I make_coco_set.py"""
import csv, json, random, zipfile
from pathlib import Path

ROOT = Path.home() / "Library/Developer/SmartAsset/phase3/data/coco"
rows = list(csv.DictReader(open(ROOT / "test_5k_mscoco_2014.csv")))
random.Random(20261107).shuffle(rows)
chosen = rows[:500]
out = ROOT / "images500"
out.mkdir(exist_ok=True)
meta = []
with zipfile.ZipFile(ROOT / "images_mscoco_2014_5k_test.zip") as z:
    names = {Path(n).name: n for n in z.namelist() if n.endswith(".jpg") and not n.startswith("__MACOSX")}
    for r in chosen:
        name = r["filename"]
        if name not in names:
            continue
        data = z.read(names[name])                 # read by exact member name; never extractall
        (out / name).write_bytes(data)
        caps = json.loads(r["raw"])
        meta.append({"file": name, "captions": [c.strip() for c in caps][:5]})
(ROOT / "captions500.json").write_text(json.dumps(meta, indent=1))
print(len(meta), "images,", sum(len(m["captions"]) for m in meta), "captions")
