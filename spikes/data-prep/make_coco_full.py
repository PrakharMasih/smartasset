"""Phase 3 (decision D5): the whole COCO 5k test split as plain data, so the vector-index comparison runs on 5,000 real image
embeddings and 25,000 real caption embeddings instead of the 500-image sample. Same source and same safety rules as
make_coco_set.py: reads the CSV, extracts JPEGs from the zip by exact member name into a fresh folder (never extractall), and
refuses any member whose name is not a plain file name.
Run inside the workspace sandbox: python3 -I make_coco_full.py"""
import csv, json, os
import zipfile
from pathlib import Path

ROOT = Path(os.environ.get("P3", Path.home() / "Library/Developer/SmartAsset/phase3")) / "data/coco"
rows = list(csv.DictReader(open(ROOT / "test_5k_mscoco_2014.csv")))
out = ROOT / "images5k"
out.mkdir(exist_ok=True)
meta, refused = [], 0
with zipfile.ZipFile(ROOT / "images_mscoco_2014_5k_test.zip") as z:
    names = {Path(n).name: n for n in z.namelist() if n.endswith(".jpg") and not n.startswith("__MACOSX")}
    for r in rows:
        name = r["filename"]
        if name not in names or "/" in name or name.startswith("."):
            refused += 1
            continue
        (out / name).write_bytes(z.read(names[name]))
        caps = [c.strip() for c in json.loads(r["raw"])][:5]
        if len(caps) == 5:
            meta.append({"file": name, "captions": caps})
(ROOT / "captions5k.json").write_text(json.dumps(meta, indent=1))
print(len(meta), "images,", sum(len(m["captions"]) for m in meta), "captions;", refused, "refused")
