#!/bin/zsh
# Downloads 200 ordinary photographs for the near-duplicate labeled set (Phase 2). They come from picsum.photos
# (Unsplash photographs) and are used only on this Mac for measurement; they are never added to the repository.
# Safe to re-run: files already there are kept.
set -u
dir=~/Library/Developer/SmartAsset/fixtures/photos
mkdir -p "$dir"
n=$(ls "$dir"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
for id in $(seq 10 600); do
  (( n >= 200 )) && break
  f="$dir/$(printf 'photo-%03d.jpg' $id)"
  [[ -s $f ]] && continue
  if curl -fsSL --max-time 30 -o "$f" "https://picsum.photos/id/$id/1600/1067.jpg" 2>/dev/null && (( $(stat -f%z "$f") > 50000 )); then
    n=$((n+1))
  else
    rm -f "$f"
  fi
done
echo "$n photos in $dir"
