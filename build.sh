#!/bin/zsh
# Builds the Rust core and SmartAsset, and installs ~/Applications/SmartAsset.app.
# Build products live in ~/Library/Developer/SmartAsset, outside the repo.
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="SmartAsset"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# With only the Command Line Tools installed, the default macOS 27 SDK turns SwiftUI's @State into a macro whose
# plugin ships only with Xcode. The macOS 26 SDK has no such macro and the app targets macOS 14 anyway.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]]; then
  [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
scratch="$HOME/Library/Developer/$name/build${SDKROOT:+26}"

# Search by meaning compiles MLX's Metal shaders, which needs Apple's Metal compiler: it ships with full Xcode (plus its
# Metal Toolchain), not with the Command Line Tools. The SDK above stays the macOS 26 one.
if [[ -z "${SA_NO_MLX:-}" && -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# The Metal Toolchain is a disk image macOS mounts under a path with a random suffix, and the build caches that path.
# When macOS mounts it somewhere else (after a restart, or after it was unmounted), the cached path is gone and every
# Metal shader fails to compile. Forget the cached manifests then; they are made again, and the shaders recompile once.
if [[ -z "${SA_NO_MLX:-}" ]]; then
  metal_now=$(xcrun -sdk macosx --find metal 2>/dev/null || true)
  if [[ -n "$metal_now" && "$(cat "$scratch/.metal-path" 2>/dev/null)" != "$metal_now" ]]; then
    rm -rf "$scratch/out/Intermediates.noindex/XCBuildData"
    mkdir -p "$scratch" && echo "$metal_now" > "$scratch/.metal-path"
  fi
fi

# The Rust core and its Swift bindings.
"$here/tools/gen-bridge.sh" | tail -1

# Sign with your Apple Development certificate when you have one. Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --product $name --package-path "$here" --scratch-path "$scratch" 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "error|warning:|Build complete" | grep -v "ld: warning" | grep -v "Conflicting identity for" | grep -v "is not used by any target" | grep -v "Invalid Exclude" | grep -v "/phase3/" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" "$here/core/crates" -name '*.swift' -newer "$bin" 2>/dev/null | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --product $name --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# Search by meaning: MLX finds its GPU kernels in mlx-swift_Cmlx.bundle inside the app's Resources (the other bundles are the
# resource bundles of the packages it uses). SwiftPM builds them next to the executable; a signed app needs them inside it.
for resources in "$scratch/$config"/*.bundle(N); do cp -R "$resources" "$app/Contents/Resources/"; done
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon needs actool, which ships with Xcode only. Without it the app uses the default icon.
if [[ -d "$here/Icon/AppIcon.icon" ]] && xcrun --find actool >/dev/null 2>&1; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
xattr -cr "$app"
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
