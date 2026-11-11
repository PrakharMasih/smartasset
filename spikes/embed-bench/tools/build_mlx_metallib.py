"""Builds mlx.metallib from the pinned MLX sources with Apple's Metal compiler, because SwiftPM cannot compile Metal shaders and
xcodebuild cannot run inside the Phase 3 sandbox (it needs Xcode's package-manifest sandbox switched off).

It follows MLX's own kernels/CMakeLists.txt: the same kernel list (read from that file, so a different MLX revision builds the
kernels that revision lists), the same compiler flags, the Metal-4 "NAX" kernels for the M5's GPU accelerators when the compiler reports
Metal >= 4, and the final link into one library. JIT is off in the Swift package, so every kernel must be here.

Usage (inside the sandbox): python3 -I build_mlx_metallib.py <mlx-swift checkout> <output dir> [min macOS, default 26.2]
Throwaway research code: not shipped."""
import os, re, subprocess, sys, time
from pathlib import Path

root = Path(sys.argv[1]) / "Source/Cmlx/mlx"
out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
min_os = sys.argv[3] if len(sys.argv) > 3 else "26.2"
kernels_dir = root / "mlx/backend/metal/kernels"
cmake = (kernels_dir / "CMakeLists.txt").read_text()

def xcrun(*args):
    return subprocess.run(["xcrun", "-sdk", "macosx", "metal", *args], capture_output=True, text=True)

version = int(subprocess.run("echo __METAL_VERSION__ | xcrun -sdk macosx metal -mmacosx-version-min=%s -E -x metal -P - | tail -1" % min_os,
                             shell=True, capture_output=True, text=True).stdout.strip() or 0)
print("Metal language version", version, "| deployment target", min_os)

# Kernel names exactly as the CMake file lists them. Conditions: fence needs Metal >= 3.2, the NAX block needs Metal >= 4.
names = []
for m in re.finditer(r"build_kernel\(\s*([\w/]+)", cmake):
    names.append(m.group(1))
def drop(pred): return [n for n in names if not pred(n)]
if version < 320: names = drop(lambda n: n == "fence")
if version < 400: names = drop(lambda n: n.endswith("_nax"))
names = list(dict.fromkeys(names))
print(len(names), "kernels")

flags = ["-x", "metal", "-Wall", "-Wextra", "-fno-fast-math", "-Wno-c++17-extensions", "-Wno-c++20-extensions", "-Wmetal-addr-spaces",
         f"-mmacosx-version-min={min_os}"]
airs, t0 = [], time.time()
for n in names:
    src = kernels_dir / f"{n}.metal"
    air = out / (Path(n).name + ".air")
    r = xcrun(*flags, "-c", str(src), f"-I{root}", "-o", str(air))
    if r.returncode != 0:
        print("FAILED", n, "\n", r.stderr[-1500:]); sys.exit(1)
    airs.append(str(air)); print(f"  {n}  ({time.time() - t0:.0f} s)", flush=True)
r = xcrun(f"-mmacosx-version-min={min_os}", *airs, "-o", str(out / "mlx.metallib"))
if r.returncode != 0:
    print("LINK FAILED\n", r.stderr[-1500:]); sys.exit(1)
size = (out / "mlx.metallib").stat().st_size
print(f"mlx.metallib {size / 1e6:.1f} MB in {time.time() - t0:.0f} s")
