#!/bin/zsh
# Builds the Rust core and regenerates the Swift bindings (docs/BRIDGE.md).
# Output: Sources/sa_ffiFFI (C header + module map) and Sources/CoreBridgeGenerated (Swift).
# Files are rewritten only when their content changes, so Swift does not rebuild for nothing.
set -euo pipefail
here=${0:A:h:h}
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cd "$here/core"
cargo build --release -p sa-ffi 2>&1 | grep -E "^(error|warning)" -A8 || true
[[ -f target/release/libsa_ffi.a ]] || { echo "Rust build failed"; exit 1; }
gen=$(mktemp -d)
cargo run -q --release -p sa-ffi --bin uniffi-bindgen -- generate \
  --library target/release/libsa_ffi.a --language swift --out-dir "$gen"
mkdir -p "$here/Sources/sa_ffiFFI" "$here/Sources/CoreBridgeGenerated"
put() { cmp -s "$1" "$2" 2>/dev/null || cp "$1" "$2"; }
put "$gen/sa_ffiFFI.h"        "$here/Sources/sa_ffiFFI/sa_ffiFFI.h"
put "$gen/sa_ffiFFI.modulemap" "$here/Sources/sa_ffiFFI/module.modulemap"
put "$gen/sa_ffi.swift"        "$here/Sources/CoreBridgeGenerated/sa_ffi.swift"
rm -rf "$gen"
echo "bridge generated"
