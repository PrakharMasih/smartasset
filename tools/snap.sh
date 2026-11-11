#!/bin/zsh
# Snapshots of every screen in light and dark, on a throwaway library with generated sample media.
#   tools/snap.sh            main window, list, folder, filters, collection, Settings tabs, Viewer
#   tools/snap.sh empty      the first-launch screen
#   tools/snap.sh missing    only the Missing page (quick iteration on one screen)
# Works only inside /tmp/sa-snapshot-data, /tmp/sa-demo-media and /tmp/sa-snapshots; nothing else is touched.
set -u
app=~/Applications/SmartAsset.app/Contents/MacOS/SmartAsset
# The app loads models only from Application Support (downloaded by the person). Tests use the verified Phase 3 copy
# unless a test models folder (SA_MODELS_ROOT) or another copy (SA_MODELS_DIR) is given.
dev_models=~/Library/Developer/SmartAsset/phase3/models/mlx
if [[ -z ${SA_MODELS_ROOT:-} && -z ${SA_MODELS_DIR:-} && -d $dev_models ]]; then export SA_MODELS_DIR=$dev_models; fi
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.prakharmasih.smartasset.savedState
rm -rf /tmp/sa-snapshot-data /tmp/sa-demo-media
mkdir -p /tmp/sa-snapshots
if [[ ${1:-} == empty ]]; then
  APP_DATA=/tmp/sa-snapshot-data APP_SNAPSHOT=/tmp/sa-snapshots APP_SNAPSHOT_EMPTY=1 $app
elif [[ ${1:-} == missing ]]; then
  APP_DATA=/tmp/sa-snapshot-data APP_DEMO=1 APP_SNAPSHOT=/tmp/sa-snapshots APP_SNAPSHOT_ONLY=missing $app
else
  find /tmp/sa-snapshots -maxdepth 1 -name '*.png' -delete
  APP_DATA=/tmp/sa-snapshot-data APP_DEMO=1 APP_SNAPSHOT=/tmp/sa-snapshots $app
fi
ls /tmp/sa-snapshots
