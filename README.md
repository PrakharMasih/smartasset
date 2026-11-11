# SmartAsset

A fast, private Mac app for creators' images, videos and audio. It indexes your folders where they already are and helps you find any asset, clean up duplicates and keep your library organised. **Everything runs on your Mac**: no account, no cloud and no uploads.

Built with a **Rust core** (storage, scanning, jobs, search) and a **native SwiftUI app** with Swift media workers.

> **Status: early development.** The library, browsing and duplicate cleanup work today. Search by meaning is in progress. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Features

**Working now**
- **Library:** add any folder (internal disk, external drive or NAS). Files are indexed in place and never copied. Changes are picked up live.
- **Unplugged drives stay searchable.** The app tells you which drive to plug in to open a file.
- **Moved or renamed files keep their tags and ratings** (matched by content).
- **Browse:** a thumbnail grid that stays smooth at 250,000 files, hover-scrub on videos, Quick Look with the spacebar, an inspector and a list view.
- **Organise:** tags, star ratings, pick/reject flags, colour labels and notes.
- **Duplicates:** finds exact copies and near-duplicates across folders and drives. Cleanup is always reviewed and confirmed, goes to the Trash only and can be undone.
- **Formats:** JPEG, PNG, HEIC, WebP, GIF, TIFF, camera RAW, MOV, MP4, M4V (H.264, HEVC, ProRes), WAV, AIFF, MP3, AAC/M4A and FLAC.

**In progress:** search by description ("golden hour drone shot over water") with EmbeddingGemma 2 on MLX, running entirely on your Mac.

**Planned:** search what was said, text in images, sound search, voice search, smart collections, a global quick-search panel and export to video editors.

## Safety promises

- **Your original files are never changed.** Scanning only reads. Dragging files out copies them. Removing a folder removes only its index data.
- The only time files move is duplicate cleanup, and only after you review and confirm. They go to the Trash, never straight to deletion.
- Only folders you add are indexed. Full Disk Access is never requested.
- Works fully offline. The only network use is an optional model download from Hugging Face.

## Requirements

- An Apple Silicon Mac running macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Rust: `brew install rustup && rustup-init`
- Optional: full Xcode with the Metal Toolchain, needed only for search by meaning (see below)

## Getting started

```sh
git clone https://github.com/PrakharMasih/smartasset.git
cd smartasset
./build.sh --open
```

This builds the Rust core and the app, installs `~/Applications/SmartAsset.app` and opens it. Then click **Add Folder** and choose a folder of media.

| Command | What it does |
| --- | --- |
| `./build.sh` | Release build and install |
| `./build.sh --debug` | Debug build and install |
| `./build.sh --open` | Install, then relaunch the app |
| `SA_NO_MLX=1 ./build.sh` | Build without search by meaning (keyword search only) |

**Search by meaning** is built only when the reviewed MLX and EmbeddingGemma 2 sources are present in `~/Library/Developer/SmartAsset/phase3` (or `SA_PHASE3_DIR`). Without them, the app still builds and runs with keyword search.

## Development

```sh
tools/test.sh            # everything: Rust clippy + tests, then the Swift tests
tools/test.sh rust       # Rust only
tools/test.sh swift      # Swift only
tools/gen-bridge.sh      # regenerate the Swift bindings after changing Rust exports
tools/snap.sh            # light and dark screenshots of every screen, saved to /tmp/sa-snapshots
tools/selftest.sh        # in-app self-test (real disk images, Trash, Quick Look)
tools/bench-grid.sh      # performance on a 250k-file library
```

The house rules are zero warnings, Rust clippy pedantic, no `unwrap()` outside tests, and Swift 6 mode with no force unwraps.

## Project layout

```
core/                 Rust workspace
  sa-core             shared types
  sa-store            SQLite storage (the source of truth)
  sa-index, sa-watch  folder scanner, live FSEvents updates
  sa-search           search
  sa-jobs             background job policy (battery, heat, pause)
  sa-dedupe           near-duplicate matching
  sa-engine           ties it together, including the duplicate-cleanup guard
  sa-ffi              UniFFI bridge to Swift
Sources/
  SmartAsset/         the SwiftUI app
  Workers/            ImageIO and AVFoundation media workers
  CoreBridge/         typed Swift over the generated bindings
  SmartAssetKit/      pure Swift logic
  SATests/            Swift test runner
docs/                 plan, roadmap, glossary, design and research
tools/                build, test, snapshot and benchmark scripts
spikes/               throwaway measurement code (not shipped)
```

## Documentation

- [docs/PLAN.md](docs/PLAN.md): product and technical plan
- [docs/ROADMAP.md](docs/ROADMAP.md): phases and progress
- [docs/GLOSSARY.md](docs/GLOSSARY.md): one name per idea
- [docs/BRIDGE.md](docs/BRIDGE.md): how Rust and Swift talk
- [docs/LICENSES.md](docs/LICENSES.md): third-party licences

## License

No licence has been chosen yet. Third-party licences are listed in [docs/LICENSES.md](docs/LICENSES.md).
