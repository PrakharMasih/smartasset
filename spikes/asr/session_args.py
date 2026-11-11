"""Prints the whisper-cli argument list that transcribes the whole speech manifest in ONE process (the model loads once, as it would in
an app), language detected automatically. Used by the system-wide memory and energy measurements, which need a steady-state session;
accuracy is scored separately with run_whispercpp.py. Usage: python3 -I session_args.py <ggml-model>"""
import json, os, shlex, sys
from pathlib import Path
P3 = Path(os.environ["P3"])
items = json.load(open(P3 / "data/asr/manifest.json"))
args = ["-m", sys.argv[1], "-l", "auto", "-nt", "-np"]
for it in items:
    args += ["-f", it["path"]]
print(" ".join(shlex.quote(a) for a in args))
