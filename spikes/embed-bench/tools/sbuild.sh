#!/bin/zsh
# usage: sbuild.sh <package dir under phase3/work> <product>
# Resolves (offline, from the pinned local clones) and builds one Phase 3 package inside the no-network sandbox, printing only errors.
# sync.sh removes SwiftPM's resolution state, so resolving first is required after every sync.
P3=~/Library/Developer/SmartAsset/phase3
pkg=$P3/work/$1
common=(--disable-sandbox --package-path $pkg --scratch-path $pkg/.build --cache-path $P3/home/cache --config-path $P3/home/config --security-path $P3/home/security)
cd /tmp
$P3/isolation/sbx.sh run /usr/bin/swift package $common resolve 2>&1 | grep -E "^error" 
$P3/isolation/sbx.sh run /usr/bin/swift build -c release --product $2 $common 2>&1 | grep -E "error:|Build complete"
