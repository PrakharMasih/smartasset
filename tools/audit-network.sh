#!/bin/zsh
# Backs the sentences on Settings > Privacy (plan H4, owner's rules of 2026-11-09):
#   "SmartAsset connects to the internet only when you choose Download Model, and only to Hugging Face."
#   1. Static: networking code exists in exactly one file (Models/ModelDownload.swift, the model download), and that file
#      names no host but huggingface.co; no networking crate in the Rust build.
#   2. Runtime: the real app, indexing, describing and searching a throwaway library for about a minute, never holds an
#      internet socket (nothing downloads unless the person chooses it).
# Exit 0 only when both hold. Touches only /tmp/sa-net-*.
set -u
here=${0:A:h:h}
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
rc=0

echo "== Static: Swift sources"
pattern='URLSession|NSURLConnection|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|CFHTTP|WKWebView|WebKit|NSNetService|MultipeerConnectivity|SCNetworkReachability|URL\(string: *"https?:|socket\(|getaddrinfo|Sparkle|FirebaseAnalytics'
download="$here/Sources/SmartAsset/Models/ModelDownload.swift"
# The pinned manifest only builds the address of a pinned file; it holds no networking API (checked by the same pattern).
pins="$here/Sources/SmartAssetKit/PinnedModels.swift"
if grep -rnE "$pattern" "$here/Sources/SmartAsset" "$here/Sources/Workers" "$here/Sources/SmartAssetKit" "$here/Sources/CoreBridge" "$here/Sources/DemoMedia" "$here/Sources/Embedding" --include='*.swift' | grep -v "^$download:" | grep -v "^$pins:[0-9]*: *return URL(string: \"https://huggingface.co/" | grep -v "^[^:]*:[0-9]*:\s*//" ; then
  echo "FAIL: networking API found above, outside the model download"; rc=1
else
  echo "PASS: no networking API outside Models/ModelDownload.swift (no Network.framework, sockets, web views, update or analytics frameworks)"
fi
hosts=$(grep -rhoE 'https?://[A-Za-z0-9.-]+' "$download" "$here/Sources/SmartAssetKit/PinnedModels.swift" | sort -u)
if [[ "$hosts" == "https://huggingface.co" ]]; then
  echo "PASS: the model download names one host, https://huggingface.co (redirects only to Hugging Face hosts over HTTPS: PinnedModels.allowsRedirect)"
else
  echo "$hosts"; echo "FAIL: the model download names another host or plain HTTP"; rc=1
fi
if grep -nE "UserDefaults.*(update|telemetry)|analytics|telemetry|Timer.*download|BGTaskScheduler|NSBackgroundActivityScheduler" "$download" | grep -v "^[0-9]*:\s*//"; then
  echo "FAIL: the download file schedules or reports something"; rc=1
else
  echo "PASS: no scheduled downloads, update checks or telemetry in the download file"
fi

echo "== Static: Rust dependencies"
cd "$here/core"
crates='reqwest|hyper|ureq|curl|surf|isahc|attohttpc|openssl|native-tls|rustls|socket2|mio-net|tungstenite|h2 |tower|axum|warp'
tree=$(cargo tree --workspace --prefix none 2>/dev/null | sed 's/ v[0-9].*//' | sort -u)
if echo "$tree" | grep -qE "^($crates)"; then
  echo "$tree" | grep -E "^($crates)"; echo "FAIL: a networking crate is in the dependency tree"; rc=1
else
  echo "PASS: no HTTP, TLS or socket crate in the Rust dependency tree"
fi
if cargo tree -e features -i tokio 2>/dev/null | grep -qE 'tokio feature "(net|full)"'; then
  echo "FAIL: tokio is built with its network feature"; rc=1
else
  echo "PASS: tokio is built without its network feature (only rt, sync, time)"
fi

echo "== Runtime: the running app"
app=~/Applications/SmartAsset.app/Contents/MacOS/SmartAsset
# With the model, so describing pictures and searching by meaning are inside the measured minute.
dev_models=~/Library/Developer/SmartAsset/phase3/models/mlx
[[ -d $dev_models ]] && export SA_MODELS_DIR=$dev_models
rm -rf /tmp/sa-net-data /tmp/sa-net-shots ~/Library/Saved\ Application\ State/com.prakharmasih.smartasset.savedState
# The full snapshot walk: indexing, duplicate hashing, every page, Settings and the Viewer (about a minute).
APP_DATA=/tmp/sa-net-data APP_DEMO=1 APP_SNAPSHOT=/tmp/sa-net-shots $app >/dev/null 2>&1 &
pid=$!
sleep 2
seen=0; samples=0; sockets=""
while kill -0 $pid 2>/dev/null; do
  out=$(lsof -nP -a -p $pid -i 2>/dev/null | tail -n +2)
  samples=$((samples+1))
  if [[ -n $out ]]; then seen=1; sockets="$sockets$out"$'\n'; fi
  sleep 0.5
done
wait $pid 2>/dev/null
if (( seen )); then
  echo "$sockets" | sort -u | head; echo "FAIL: the app held an internet socket"; rc=1
elif (( samples < 40 )); then
  echo "UNVERIFIED: only $samples samples; the run was too short to mean anything"; rc=1
else
  echo "PASS: no internet socket in $samples samples (twice a second) while indexing, hashing and drawing a demo library"
fi
rm -rf /tmp/sa-net-data /tmp/sa-net-shots
exit $rc
