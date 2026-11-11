#!/bin/zsh
# Runs every Rust and Swift test. Exit status 0 only when all pass.
#   tools/test.sh            everything
#   tools/test.sh swift      only the Swift runner (optionally: tools/test.sh swift "bridge:")
#   tools/test.sh rust       only the Rust workspace
set -uo pipefail
here=${0:A:h:h}
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
# With only the Command Line Tools, the default macOS 27 SDK needs an Xcode-only macro plugin for SwiftUI (see build.sh).
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]]; then
  [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
scratch="$HOME/Library/Developer/SmartAsset/build${SDKROOT:+26}"
rc=0
if [[ ${1:-all} != swift ]]; then
  echo "== Rust"
  (cd "$here/core" && cargo clippy --workspace --all-targets -- -D warnings 2>&1 | grep -E "^(error|warning)" -A6 | head -40) | grep . && rc=1
  (cd "$here/core" && cargo test --workspace --exclude sa-ffi 2>&1 | grep -E "^test result|FAILED|panicked|error(\[|:)") || rc=1
fi
"$here/tools/audit-motion.sh" || rc=1
"$here/tools/grid-lint.sh" | tail -1 || rc=1
if [[ ${1:-all} != rust ]]; then
  echo "== Swift"
  "$here/tools/gen-bridge.sh" >/dev/null || rc=1
  swift build --product SATests --scratch-path "$scratch" 2>&1 | grep -E "error|warning: " | grep -v "ld: warning" \
    | grep -v "Conflicting identity for" | grep -v "is not used by any target" | grep -v "Invalid Exclude" | grep -v "/phase3/" && rc=1
  "$scratch/debug/SATests" "${2:-}" || rc=1
fi
exit $rc
