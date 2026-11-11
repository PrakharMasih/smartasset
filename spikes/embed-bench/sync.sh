#!/bin/zsh
# Copies the benchmark sources from the repository into the isolated Phase 3 workspace (the run profile cannot read the repository).
set -e
src=${0:A:h}
dst=~/Library/Developer/SmartAsset/phase3/work
mkdir -p ~/Library/Developer/SmartAsset/phase3/tools/asr && rsync -a $src/../asr/ ~/Library/Developer/SmartAsset/phase3/tools/asr/
for d in bench-support provider-kit measure-bench mlx-bench litert-bench whisperkit-bench; do
  [[ -d $src/$d ]] && rsync -a --delete --exclude .build --exclude SourcePackages --exclude DerivedData "$src/$d/" "$dst/$d/"
done
echo synced
