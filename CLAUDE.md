# SmartAsset

A fast, private Mac app for creators' images, videos and audio: a **Rust core** (storage, scanning, jobs, search) with a
**native SwiftUI app** and Swift media workers. Everything runs on the Mac. The plan is `docs/PLAN.md`; status is `docs/STORIES.md`.
**Work proceeds phase by phase from `docs/ROADMAP.md`: do not start a phase until the previous phase's validation gate passes,
and tick items there with evidence as they are done.**

## Layout

- `core/` Cargo workspace: `sa-core` (types), `sa-store` (SQLite, source of truth), `sa-search`, `sa-index` (scanner), `sa-watch` (FSEvents),
  `sa-jobs` (policy), `sa-providers` (work contracts + fake workers), `sa-dedupe` (near-duplicate matching, pure), `sa-engine` (composition root, no FFI;
  includes the hash runner and the cleanup guard), `sa-ffi` (UniFFI bridge).
- `Sources/CoreBridge` typed Swift over the generated bindings; `Sources/CoreBridgeGenerated` and `Sources/sa_ffiFFI` are generated (git-ignored).
- `Sources/Workers` ImageIO / AVFoundation media workers and the pull loop. `Sources/SmartAssetKit` pure logic. `Sources/DemoMedia` generated sample media.
- `Sources/SmartAsset` the app: `App/` (model, boot, commands), `Library/` (sidebar, grid, list, inspector), `Duplicates/` (page, review sheet, Trash), `Viewer/`, `Settings/`, `UI/` (tokens).
- `Sources/SATests` the Swift test runner (see below). `docs/` plan, glossary, design, stories, bridge, licences.
- `build.sh` builds Rust + Swift and installs `~/Applications/SmartAsset.app`. There is no Xcode project.

## Build and check

- Build and install: `./build.sh` (`--open` to relaunch). Zero warnings is the rule.
- **All tests:** `tools/test.sh` (Rust clippy `-D warnings` + tests, then the Swift runner). `tools/test.sh rust` / `swift ["name filter"]`.
  `swift test` does not work with Command Line Tools only (no Testing macro plugin, no XCTest), so Swift tests are an executable target.
- With Command Line Tools only, build against the macOS 26 SDK: `build.sh` and `tools/test.sh` set `SDKROOT` for you; set it yourself for raw
  `swift build` (`export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`, scratch path `~/Library/Developer/SmartAsset/build26`).
- After changing Rust exports: `tools/gen-bridge.sh` (regenerates the Swift bindings).
- After a UI change: `tools/snap.sh` (generated demo library, light and dark PNGs of every screen in `/tmp/sa-snapshots`; `tools/snap.sh empty` for first launch)
  and look at them. Then `tools/grid-lint.sh` (4 pt grid).
- Performance: `tools/bench-grid.sh` (250k-file library: launch, scroll smoothness, memory, idle CPU). Rust query benchmark:
  `cargo test -p sa-search --release --test search -- --ignored --nocapture`.
- In-app self-test: `tools/selftest.sh` (real disk images, real Trash, real Quick Look); `SELFTEST_ONLY="duplicates:" tools/selftest.sh` runs one check.
- The near-duplicate labeled set needs photos: `tools/fetch-photo-fixtures.sh` (200 photos, kept outside the repo). `tools/audit-network.sh` backs the Privacy page (networking only in `Models/ModelDownload.swift`, to Hugging Face). `tools/offline-check.sh` runs the model self-tests with internet denied. The app loads models only from Application Support; tools set `SA_MODELS_DIR` to the verified Phase 3 copy; `SA_NETWORK_TESTS=1 SA_MODELS_ROOT=/tmp/… SELFTEST_ONLY="model download"` tests a real download.
- `spikes/` throwaway measurement code (not shipped, outside the Cargo workspace): `vector-bench` (synthetic spike, `eval` retrieval scorer, `real` exact-vs-HNSW and measured memory),
  `data-prep` (test sets), `embed-bench` (embedding harnesses: LiteRT, MLX, WhisperKit, shared `bench-support`), `asr` (transcription driver, scorer, comparison), `creator-eval` (creator-media dataset validator).
  Phase 3 models and datasets live in `~/Library/Developer/SmartAsset/phase3`; findings in `docs/research/phase3-model-spikes.md`, method in `phase3-proxy-benchmarks.md`, raw outputs in `docs/research/phase3-results/`.
  **Third-party runtimes are built and run only through `phase3/isolation/sbx.sh`** (`run` = no network, `fetch` = network, both deny personal files; the repo is unreadable there, so `spikes/embed-bench/sync.sh` copies sources in).
  Build a Phase 3 package: `~/Library/Developer/SmartAsset/phase3/tools/sbuild.sh <package> <product>` (resolves offline, then builds in the sandbox). SwiftPM cannot compile Metal shaders and `xcodebuild` cannot run inside the sandbox, so MLX's `mlx.metallib` is built by `spikes/embed-bench/tools/build_mlx_metallib.py` and copied next to the binary. The Metal Toolchain (Apple, build 27B47) is installed.
  Language scope: **English first**, other languages later (plan §16). Energy needs root: the owner runs `spikes/asr/energy_session.sh`; never use `sudo` or change Xcode defaults to get around the sandbox.
  Rust for the spikes: `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`. No blanket Bash permission rules. Phase 3 selects candidates; only creator-media results and hardware tests select a runtime.
  Full Xcode is at `/Applications/Xcode.app`: use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for builds that need the Metal compiler.
- Third-party code (model runtimes, packages) is read first and only built or run with the owner's permission; model files are fetched as plain data and checked against published SHA-256.
- Snapshots, demo data and the bench refuse to run unless `APP_DATA` is in /tmp. Never test against `~/Library/Application Support/SmartAsset/`.

## Rules that keep it correct

- **Originals are never changed** (plan §3.2). Scanning only reads. Drag-out is copy-only. Removing a folder removes index data only.
- **Files move only in duplicate cleanup, and only through the guard** (`sa-engine/src/cleanup.rs`): review, confirm, Trash. Rust approves, Swift moves, nothing is deleted.
- Show errors with `error.userMessage`, never `localizedDescription` (the generated text is a debug dump).
- "Missing" is set only after a *completed* scan that could see the directory. Cancel, unreadable folders, unplugged drives and a folder that
  suddenly looks empty never mark files missing.
- No media bytes cross the bridge. Workers pull batches (`next_media_batch` / `submit_media_results`), results commit in one transaction and are
  discarded if the file changed.
- Rust: clippy pedantic as errors, no `unwrap()` outside tests, `unsafe` only in `sa-ffi`. Swift: Swift 6 mode, no force unwraps in production code.
- `AVAssetReader` and similar AVFoundation initialisers raise Objective-C exceptions for invalid parameters; Swift cannot catch them. Validate first.
- Changing a locked feature or decision needs an entry in `docs/PLAN.md` §16.

## Design rules

- Use the bama skills before UI work: `ux-design`, `mac-design`, `design-system`, `layout-grid`, `build-and-verify`. Native look; no custom design kit.
- Only the accent colour is custom (`UI/Theme.swift`). Spacing from `Space` on a 4 pt grid. Windows open calm (`.noInitialFocus()`).
- One name per idea: `docs/GLOSSARY.md`. Every action has a menu item; every icon-only button has `.help`.
- Never hard-code colours in views (Color Labels are the one exception: their meaning is the colour).

## Git

- Commit only when the owner asks. Messages say what the user can now do.
