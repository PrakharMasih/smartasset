"""Phase 3 proxy test set: 500 COCO val2017 images with their 5 human captions each (CC BY 4.0 captions; Flickr images).
Reads only captions_val2017.json out of the big annotations zip using HTTP range requests, then downloads 500 images.
Used only for local measurement; nothing here is committed or shipped."""
import io, json, random, subprocess, sys, zipfile
from pathlib import Path

OUT = Path.home() / "Library/Developer/SmartAsset/phase3/data/coco"
ZIP = "https://images.cocodataset.org/annotations/annotations_trainval2017.zip"

class HTTPRangeFile(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos = url, 0
        head = subprocess.run(["curl", "-sIL", "--max-time", "60", url], capture_output=True, text=True).stdout
        self.size = int([l.split(":")[1] for l in head.splitlines() if l.lower().startswith("content-length")][-1])
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos
    def read(self, n=-1):
        if n < 0: n = self.size - self.pos
        if n == 0 or self.pos >= self.size: return b""
        end = min(self.size - 1, self.pos + n - 1)
        data = subprocess.run(["curl", "-sL", "--max-time", "120", "-r", f"{self.pos}-{end}", self.url], capture_output=True).stdout
        self.pos += len(data)
        return data
    def readinto(self, b):
        data = self.read(len(b)); b[:len(data)] = data; return len(data)

def main():
    z = zipfile.ZipFile(HTTPRangeFile(ZIP))
    caps = json.loads(z.read("annotations/captions_val2017.json"))
    by_image = {}
    for a in caps["annotations"]:
        by_image.setdefault(a["image_id"], []).append(a["caption"].strip())
    ids = sorted(i for i, c in by_image.items() if len(c) >= 5)
    random.Random(20261107).shuffle(ids)
    ids = ids[:500]
    meta = []
    for n, i in enumerate(ids):
        name = f"{i:012d}.jpg"
        dest = OUT / "images" / name
        if not dest.exists() or dest.stat().st_size < 5000:
            try:
                subprocess.run(["curl", "-sfL", "--max-time", "60", "-o", str(dest), f"https://images.cocodataset.org/val2017/{name}"], check=True)
            except Exception as e:
                print("skip", name, e); continue
        meta.append({"file": name, "captions": by_image[i][:5]})
        if n % 100 == 0: print(n, flush=True)
    (OUT / "captions.json").write_text(json.dumps(meta, indent=1))
    print("images:", len(meta), "captions:", sum(len(m["captions"]) for m in meta))

main()
