"""Download files from a Hugging Face model repo as plain data and verify each against the SHA-256 Hugging Face publishes
(the git-LFS object id). Uses curl (this Python's certificate store is unusable). Nothing is executed.
Usage: python3 -I fetch_hf.py <repo> <dest-dir> <path-prefix-or-file> [<more> ...]
A dataset repository is given as datasets/<owner>/<name> (for example datasets/google/fleurs).
A prefix ending in '/' downloads the whole folder; otherwise it is a single file."""
import hashlib, json, subprocess, sys
from pathlib import Path

repo, dest = sys.argv[1], Path(sys.argv[2])
api_kind, resolve_kind = ("datasets", "datasets/") if repo.startswith("datasets/") else ("models", "")
repo = repo.removeprefix("datasets/")
wanted = sys.argv[3:]

def curl_json(url):
    out = subprocess.run(["curl", "-fsSL", "--max-time", "120", url], capture_output=True, text=True, check=True).stdout
    return json.loads(out)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

files = []
for w in wanted:
    if w.endswith("/"):
        files += [f for f in curl_json(f"https://huggingface.co/api/{api_kind}/{repo}/tree/main/{w.rstrip('/')}?recursive=true") if f["type"] == "file"]
    else:
        parent, name = (w.rsplit("/", 1) + [""])[:2] if "/" in w else ("", w)
        listing = curl_json(f"https://huggingface.co/api/{api_kind}/{repo}/tree/main/{parent}" if parent else f"https://huggingface.co/api/{api_kind}/{repo}/tree/main")
        files += [f for f in listing if f["path"] == w]
total = sum(f["size"] for f in files)
print(f"{len(files)} files, {total/1e6:.0f} MB", flush=True)
bad = 0
for f in files:
    target = dest / f["path"]
    expected = (f.get("lfs") or {}).get("oid")
    if target.exists() and target.stat().st_size == f["size"] and (not expected or sha256(target) == expected):
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["curl", "-fsSL", "--retry", "5", "--retry-delay", "3", "-C", "-", "-o", str(target),
                        f"https://huggingface.co/{resolve_kind}{repo}/resolve/main/{f['path']}"])
    if r.returncode != 0:
        print("DOWNLOAD FAILED", f["path"]); bad += 1; continue
    if expected and sha256(target) != expected:
        print("CHECKSUM MISMATCH", f["path"]); target.unlink(); bad += 1
print("done;", "all files verified" if not bad else f"{bad} problems", flush=True)
sys.exit(1 if bad else 0)
