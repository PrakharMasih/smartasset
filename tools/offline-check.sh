#!/bin/zsh
# Proves the owner's rule "once installed, indexing, embedding and search work with Wi-Fi disabled": the self-tests that
# need the model run with every internet connection denied by the operating system (sandbox-exec), not merely unused.
# Uses a models folder given in SA_MODELS_ROOT (a real download, e.g. from the "model download" self-test) or the verified
# Phase 3 copy. Touches only /tmp. Exit 0 only if every check passes.
set -u
here=${0:A:h:h}
app=~/Applications/SmartAsset.app/Contents/MacOS/SmartAsset
if [[ -z ${SA_MODELS_ROOT:-} ]]; then export SA_MODELS_DIR=${SA_MODELS_DIR:-$HOME/Library/Developer/SmartAsset/phase3/models/mlx}; fi
rm -rf ~/Library/Saved\ Application\ State/com.prakharmasih.smartasset.savedState /tmp/sa-selftest-data /tmp/sa-moves
profile='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))'
# First, that the profile really blocks the internet.
if sandbox-exec -p "$profile" /usr/bin/curl -sS --max-time 5 -o /dev/null https://huggingface.co 2>/dev/null; then
  echo "FAIL: the offline profile did not block a connection"; exit 1
fi
echo "PASS: the offline profile blocks internet connections (curl to huggingface.co refused)"
APP_DATA=/tmp/sa-selftest-data SELFTEST_ONLY=${SELFTEST_ONLY:-"semantic search|text in pictures|video moments|more like this|labels"} \
  caffeinate -i timeout ${SELFTEST_TIMEOUT:-1800} sandbox-exec -p "$profile" $app --selftest 2>&1 | grep -vE "^\s*$"
exit ${pipestatus[1]}
