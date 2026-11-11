#!/bin/zsh
# Opens a synthetic 250,000-file library (no thumbnails, so this measures paging, drawing and memory, not decoding)
# and reports launch time, scroll smoothness, memory and idle CPU. Works only inside /tmp/sa-250k.
set -u
here=${0:A:h:h}
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
if [[ ! -f /tmp/sa-250k/library.sqlite ]]; then
  (cd "$here/core" && SA_BENCH_DB=/tmp/sa-250k cargo test -p sa-search --release --test search -- --ignored --nocapture 2>&1 | grep -E "insert|test result")
fi
APP_DATA=/tmp/sa-250k APP_BENCH=1 ~/Applications/SmartAsset.app/Contents/MacOS/SmartAsset 2>&1 | grep BENCH
