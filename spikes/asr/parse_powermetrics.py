"""Summarises a powermetrics log: mean power (mW) of the CPU, GPU and Neural Engine during idle (the first N seconds) and during the
workload, and the workload's energy above idle in joules. Usage: python3 -I parse_powermetrics.py <log> <idle seconds> <workload seconds>"""
import json, re, sys
text = open(sys.argv[1], errors="replace").read()
idle_s, work_s = float(sys.argv[2]), float(sys.argv[3])
blocks = text.split("*** Sampled system activity")[1:]
rows = []
for b in blocks:
    def grab(pat):
        m = re.search(pat, b)
        return float(m.group(1)) if m else 0.0
    ms = grab(r"\((\d+\.\d+)ms elapsed\)") or 500.0
    rows.append({"ms": ms, "cpu": grab(r"CPU Power: (\d+) mW"), "gpu": grab(r"GPU Power: (\d+) mW"), "ane": grab(r"ANE Power: (\d+) mW"),
                 "pkg": grab(r"Combined Power \(CPU \+ GPU \+ ANE\): (\d+) mW")})
t, idle, work = 0.0, [], []
for r in rows:
    (idle if t < idle_s * 1000 else work).append(r); t += r["ms"]
def mean(rs, k): return sum(r[k] for r in rs) / len(rs) if rs else 0.0
out = {"samples_idle": len(idle), "samples_workload": len(work), "workload_seconds": work_s}
for k in ("cpu", "gpu", "ane", "pkg"):
    out[f"idle_mw_{k}"] = round(mean(idle, k)); out[f"workload_mw_{k}"] = round(mean(work, k))
out["workload_energy_above_idle_joules"] = round(sum((r["pkg"] - mean(idle, "pkg")) * r["ms"] for r in work) / 1e6, 1)
out["workload_peak_mw_pkg"] = round(max((r["pkg"] for r in work), default=0))
print(json.dumps(out, indent=1))
