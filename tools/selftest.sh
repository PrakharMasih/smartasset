#!/bin/zsh
# Runs the in-app self-test on a throwaway library: hover-scrub, Quick Look, drag pasteboard, accessibility audit,
# a real disk image unplugged and replugged, and folders moved while the app is open and closed. Exit 0 = all pass.
# Touches only /tmp/sa-selftest-data, /tmp/sa-selftest-media, /tmp/sa-moves and a disk image in /tmp.
set -u
app=~/Applications/SmartAsset.app/Contents/MacOS/SmartAsset
# The app loads models only from Application Support (downloaded by the person). Tests use the verified Phase 3 copy
# unless a test models folder (SA_MODELS_ROOT) or another copy (SA_MODELS_DIR) is given.
dev_models=~/Library/Developer/SmartAsset/phase3/models/mlx
if [[ -z ${SA_MODELS_ROOT:-} && -z ${SA_MODELS_DIR:-} && -d $dev_models ]]; then export SA_MODELS_DIR=$dev_models; fi
rm -rf ~/Library/Saved\ Application\ State/com.prakharmasih.smartasset.savedState
rm -rf /tmp/sa-selftest-data /tmp/sa-moves
# caffeinate: a long run must not be cut by idle sleep (a sleeping Mac also stops the GPU work under test).
APP_DATA=/tmp/sa-selftest-data caffeinate -i timeout ${SELFTEST_TIMEOUT:-600} $app --selftest 2>&1 | grep -vE "^\s*$"
exit ${pipestatus[1]}
