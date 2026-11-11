"""Lists the media in a dataset folder into items.json, ready for a person to complete. Usage: python3 -I ingest.py <dataset-dir>

The dataset folder is where the owner copies media they made, licensed, or have written consent for (outside any repository and any
cloud-synced folder; inside ~/Library/Developer/SmartAsset/phase3/data/creator so the isolated experiments can read it).
For every audio, video or image file this records id, relative path, kind, size, sha256 and duration. It does NOT guess what a person
must decide: `stratum`, `language` and `permission` stay empty, and `validate_dataset.py` fails until they are filled in.
Existing entries are kept as they are (matched by sha256), so re-running after adding files is safe. Files are only read."""
import hashlib, json, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
KINDS = {**{e: "audio" for e in (".wav", ".aif", ".aiff", ".mp3", ".m4a", ".aac", ".flac", ".caf")},
         **{e: "video" for e in (".mp4", ".mov", ".m4v", ".mkv", ".webm")},
         **{e: "image" for e in (".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".webp")}}
existing = {i["sha256"]: i for i in json.loads((root / "items.json").read_text())} if (root / "items.json").exists() else {}

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def seconds(p):
    """Duration from Spotlight metadata, else from afinfo. 0.0 means neither could read it: ingest warns, and the validator rejects moments in it."""
    r = subprocess.run(["/usr/bin/mdls", "-name", "kMDItemDurationSeconds", "-raw", str(p)], capture_output=True, text=True)
    try: return round(float(r.stdout), 2)
    except ValueError: pass
    r = subprocess.run(["/usr/bin/afinfo", str(p)], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if "estimated duration" in line:
            try: return round(float(line.split(":")[1].split()[0]), 2)
            except (ValueError, IndexError): pass
    return 0.0

items, new = [], 0
for p in sorted(root.rglob("*")):
    if not p.is_file() or p.suffix.lower() not in KINDS or p.name.startswith("."): continue
    digest = sha256(p)
    if digest in existing:
        kept = {**existing[digest], "path": str(p.relative_to(root))}
        if kept.get("kind") != "image" and not kept.get("seconds"): kept["seconds"] = seconds(p)    # retry a duration that could not be read before
        items.append(kept); continue
    new += 1
    items.append({"id": f"m{len(items) + 1:04d}", "path": str(p.relative_to(root)), "kind": KINDS[p.suffix.lower()], "sha256": digest,
                  "bytes": p.stat().st_size, "seconds": seconds(p) if KINDS[p.suffix.lower()] != "image" else 0,
                  "stratum": None, "language": None, "permission": None,
                  "note": "TO FILL: stratum, language (en|hi|hinglish|none), permission {basis, note}"})
(root / "items.json").write_text(json.dumps(items, indent=1, ensure_ascii=False))
todo = [i for i in items if not (i.get("stratum") and i.get("language") and (i.get("permission") or {}).get("basis"))]
unreadable = [i["path"] for i in items if i["kind"] != "image" and not i.get("seconds")]
if unreadable: print("WARNING: no duration could be read for:", ", ".join(unreadable[:10]))
print(f"{len(items)} items ({new} new); {len(todo)} still need a stratum, a language and a permission basis")
