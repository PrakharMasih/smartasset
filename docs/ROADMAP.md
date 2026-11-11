# SmartAsset Roadmap and Progress

This file tracks everything **not yet developed**, broken into phases. Work one phase at a time. A phase is closed only when
**every item in its Validation gate passes**. Then tick it, record the date and evidence, and move to the next phase.

- Plan and locked features: `docs/PLAN.md`. Feature status: `docs/STORIES.md`. What is already built: Phase 0 below.
- Feature IDs (L1, S3, A2…) refer to PLAN.md §4.
- How to tick an item: `- [x]` plus a short note with the evidence (test name, bench number, snapshot, date).
- Standard checks for every phase (in addition to its own gate):
  - `tools/test.sh` green: clippy clean, all Rust and Swift tests pass, zero Swift warnings.
  - `tools/snap.sh` light and dark snapshots reviewed for every screen the phase touched; `tools/grid-lint.sh` passes.
  - `tools/bench-grid.sh` shows no regression against the last recorded numbers.
  - File safety: originals unchanged (byte-for-byte check on the test media).
  - `docs/STORIES.md` and this file updated; any change to a locked feature logged in PLAN.md §16.

## Progress overview

| Phase | Name | Milestone (PLAN §13) | Status |
| --- | --- | --- | --- |
| 0 | Library foundation | M1 (core) | ✅ Done 2026-11-05 |
| 1 | Finish and verify the Library | M1 (gaps) | 🟨 Automated gate passed; 4 manual checks remain |
| 2 | Duplicates and cleanup | M4 | 🟨 Built and verified; heavy-crop recall and a human accessibility pass remain |
| 3 | Model and retrieval spikes | M0 (remaining) | 🟨 Candidates measured on proxy sets (LiteRT-LM, whisper.cpp, WhisperKit), vector decision made on real vectors; nothing selected. MLX needs the Metal Toolchain (your approval); creator media, 8 GB and 24–32 GB Macs and pass bars need you |
| 4 | Vector engine and visual search | M2 | 🟦 Started 2026-11-07 under an owner waiver of the Phase 3 gate (PLAN §16); results unvalidated, release gate unchanged |
| 5 | Audio and voice | M3 | ⬜ Blocked by Phase 3 |
| 6 | Hardening | M4.5 | ⬜ Not started |
| 7 | Private beta | MVP | ⬜ Blocked by 1–6 |
| 8 | Creator power | M5 (1.0) | ⬜ Not started |
| 9 | Mac-wide access | M6 (1.0) | ⬜ Not started |
| 10 | Public release | M6 (ship) | ⬜ Not started |

Phases 1 and 2 needed nothing outside this Mac. Phase 3 needs inputs listed in its section.

---

## Phase 0 · Library foundation ✅ (done 2026-11-05)

Rust core (store, scanner, watcher, jobs, search, engine, bridge), Swift media workers, grid, list, inspector, Viewer, Settings,
organizing, filters, smart collections. 118 Rust tests, 24 Swift tests. 250k-file grid: ~0.26 s open, 93–121 MB, 0.01 % idle CPU,
p99 timer lateness 3.3 ms at 15,000 pt/s. Details in `docs/STORIES.md`.

---

## Phase 1 · Finish and verify the Library (M1 gaps)

Goal: every M1 feature is exercised for real, not just compiled.

**Status (2026-11-05): automated gate passed; 4 manual checks remain (listed at the end). Not closed until you tick those.**

### Build
- [x] H2 Missing-file repair: Missing page with **Find in Folder…** (recognises moved files by content) and **Remove from Library…** (confirmation; removal can only ever touch files already marked missing; disk never touched). *Evidence:* Rust test `only_missing_files_can_be_removed_from_the_library`; self-test "missing files" (2 deleted → missing, 1 moved → relinked with rating, removal took only the 2, disk untouched); snapshots `missing-light/dark`. Found and fixed a layout bug on the way (a long one-row banner collapsed the sidebar and content panes)
- [x] H3 first-run second step: after the very first folder a one-time banner offers **Choose Models**. *Implemented; not covered by a test* (it is suppressed in snapshot mode)
- [~] Keyboard focus and VoiceOver: **automated part done** (below); a human VoiceOver listening pass and a Tab-order pass are still manual
- [~] Reduce Motion done (`tools/audit-motion.sh`: the app has no custom animations; system transitions follow the setting). Increase Contrast **not verified** (badges are dark capsules with white text; no run with the setting on)
- [x] Undo for folder on/off and for *removing* an exclusion. Adding an exclusion is deliberately not undoable (it would not bring back the ratings and tags that left with the files), and its sheet says so. *Evidence:* self-test "undo"
- [x] Self-test hooks: `SmartAsset --selftest` / `tools/selftest.sh` drives the real app (synthesised hover events on real tiles, the real Quick Look panel, the real drag pasteboard, key events on the grid, a real disk image, real folder moves, the Accessibility API)

### Validation gate
- [x] **Formats:** real files for every L6 format. 8 real camera RAWs (Apple DNG, Canon CR3, Fujifilm RAF, Leica DNG, Nikon NEF, Olympus ORF, Panasonic RW2, Sony ARW, from raw.pixls.us, CC0), WebP, HEVC, ProRes 422, M4V, AIFF, AAC/M4A, FLAC, MP3: metadata and thumbnail verified (RAW 5–93 ms via the embedded preview). RAW from cameras macOS does not support (3 older bodies) fail as *unsupported* with a message naming RAW, not as "corrupt". Fixed on the way: that classification. Fixture generation needs `cwebp`, `afconvert`, `lame` (brew)
- [x] **Hover-scrub (V2):** on real tiles, first and last frames differ; filmstrip made once (0.3 s), cached frame swap **0.009 ms** (target < 50 ms); strip persisted and reloaded (16 frames from an 81 KB file); leaving restores the poster. *Synthesised mouse events, not a physical pointer*
- [x] **Quick Look (V3):** opens on the selection, 50 files to arrow through, closes; a multi-selection previews exactly those files
- [~] **Drag out (W1):** drag policy is copy-only (a constant shared by grid and list), a tile or row carries only a file URL and our id, and the original is byte-identical afterwards. **Actual drops into Final Cut Pro, Premiere Pro, DaVinci Resolve, a browser upload box and Finder are manual**
- [x] **Drives (L4):** a real APFS disk image mounted, indexed, ejected, remounted: while ejected 12 files stay searchable, dimmed, name "SAProofDisk", paths absent, 0 marked missing, no work leased, a rescan changes nothing; after remount rating, tag and path are back
- [x] **Folder moved (H2):** while the app is open (library follows via the bookmark after the scan fails) and while it is closed (relaunch follows): same records, rating and tag kept, 0 missing. Fixed on the way: a failing scan now makes the app try its bookmark
- [~] **iCloud Drive and NAS:** **unverified.** iCloud Drive refuses this process (macOS privacy protection) and there is no SMB share to mount. The disk-image test covers the same offline/online code; the cloud-only skip logic is unit-tested for the flag only
- [~] **Keyboard only:** keys 1–5, 0, P, X, U, Return (opens the Viewer) and ⌘Z drive the real grid; 22 actions all have menu items. **Tab order, sidebar and sheet operation by keyboard are manual**
- [x] **Accessibility tree:** via the real Accessibility API, 174 elements walked, 15 controls all named, every visible tile named. Found and fixed: 8 unnamed star/flag buttons, the unnamed tag field, and an off-main-thread accessibility call that the runtime flagged as a data race
- [x] **Layout:** `tools/check-layout.swift` passes on all 32 snapshot layout files (inspector probes added)
- [x] Standard checks: clippy clean, 119 Rust tests, 29 Swift tests (incl. formats), 11 in-app self-tests, `grid-lint`, `audit-motion`, light/dark snapshots (incl. new Missing page) reviewed. **Performance re-measured:** 250k grid, 15,000 pt/s flick: p99 ≈ 8 ms, 0.1–1.4 % late ticks, 105–115 MB, 0.01 % idle CPU. The recheck found a regression (badge text and symbols were rebuilt on every redraw: ~half of main-thread time) and fixed it by pre-rendering each badge once; it is a little worse than the earlier lighter-library run (p99 3.3 ms), so it stays on the watch list for Phase 6

### Manual checks that close Phase 1 (about 20 minutes)
1. **Drag into editors:** drag one file and a multi-selection from the grid into Final Cut Pro, Premiere Pro, DaVinci Resolve, a browser upload page, and Finder. Confirm each receives the file, and the original stays where it was.
2. **iCloud Drive:** add a folder from iCloud Drive that contains files not downloaded to this Mac. Confirm the notice "N files … only in iCloud … skipped" and that nothing starts downloading.
3. **Network share:** add a folder on an SMB/NAS share, disconnect, reconnect. Same expectations as the disk-image test.
4. **VoiceOver, Tab order, Increase Contrast:** turn each on and walk the main window, inspector, Viewer, Settings and the Add/Remove/Exclude sheets.

## Phase 2 · Duplicates and cleanup (M4: A1, A2-lite, A3, H4)

Needs no AI model. A2's embedding confirmation waits for Phase 4; perceptual-hash matching ships here.

**Status (2026-11-07): built and verified by automated tests, two real drives and the real Trash. Started at the owner's request
while Phase 1's four manual checks were still open (they remain open). Not closed: one gate item is only partly met (heavy crops,
below), and the manual VoiceOver / Increase Contrast pass on the new page has not been done.**

### Build
- [x] Full-content BLAKE3 hash job. `sa-engine/src/hasher.rs`: leased through the job manager like every other job (maintenance lane), held while paused / on battery / hot, starts only when no scan runs and the thumbnails are done, 1 MiB reads so a pause stops it mid-file, one transaction per batch, nothing partial is ever stored. **Only files that share size and quick hash with another file are read in full** (only those can be copies), so a library is never read end to end. 2.1 GB/s on one reader with a warm cache
- [x] A1 exact duplicates: groups by size + full hash, present files only, offline-drive files included, read-only (`sa-store/src/dedupe.rs`)
- [x] A2 near duplicates (perceptual hash): a 64-bit difference hash and a 64-bit DCT hash per picture (one per keyframe at 20 / 50 / 80 % for video), made by the Swift worker (`Workers/Perceptual*.swift`) from the existing thumbnail, matched in Rust (`sa-dedupe`: multi-index hashing, anchor-based groups, flat pictures and smooth gradients never matched). 1.8 ms per picture; grouping 262,500 pictures takes 2.7 s. **Audio is exact-only** (no audio fingerprint). The embedding confirmation for A2 is Phase 4
- [x] Duplicates page (sidebar ▸ Duplicates, ⌥⌘D): Exact Copies and Similar tabs, groups with the files side by side, full location, size, modified date, match, suggested copy to keep, space that could be freed; explanatory empty / waiting / paused states
- [x] A3 cleanup: tick copies (or **Select Extra Copies**, per group or in all groups) → one review sheet listing every file with size, modified date, full location and match, and what stays → **Move to Trash** → banner with **Undo** (puts the files back, byte-identical) and ⌘Z; tags, ratings, collections and notes of a removed copy move to the copy that stays
- [x] File-safety guard in Rust (`sa-engine/src/cleanup.rs`), see the gate
- [x] H4 Privacy page (Settings ▸ Privacy). The "no network connections" line is backed by `tools/audit-network.sh`
- [x] L3 hardened with the full hash: a moved file (or a freshly added twin) is relinked only if its full hash matches the old file's, whenever the library has one (files up to 512 MiB, 4 GiB per scan; beyond that the quick hash decides as before)
- [x] Found on the way: **every error shown in the app was UniFFI's debug text** (`BridgeError.Refused(message: …)`); errors now show their own sentence (`Error.userMessage`)

### Validation gate
- [x] **Exact duplicates across folders and drives, 100 % recall, 0 false groups.** Engine test `exact_copies_are_found_and_look_alikes_are_not`: 14 files in 3 folders, 3 known sets of copies (2, 3 and 2 files, under different names), found exactly; two files with the same size *and* the same first / middle / last 16 KiB but one differing byte are kept apart (both read in full, hashes differ); files that cannot be copies of anything were never read in full. In-app self-test: **two real mounted APFS disk images**, copies under other names, 2 groups found, the unrelated picture not grouped
- [~] **Near duplicates, precision and recall measured on a labeled set.** 200 real photographs (picsum.photos / Unsplash, 1600 px) × 10 changes = 2,200 pictures, about 20,000 distinct photo pairs, run through the real worker pipeline (512 px thumbnail → hash) and the real matcher. Limits chosen: **DCT hash ≤ 10 bits and difference hash ≤ 12 bits of 64.** There, **0 false pairs** (first false pairs appear at 12 / 12). Recall of a changed copy grouped with its original: resize to 50 % 100 %, to 25 % 100 %; re-encode JPEG q40 100 %, q10 100 %; brighter 99 %; less contrast and saturation 99 %; grayscale 100 %; **crop 5 % 99 %, crop 10 % 89 %, crop 20 % 19 %**. Videos: 10 clips, each re-exported three ways (960×540, medium quality, HEVC 1080p), **100 % recall, 0 false pairs**. *Partly met:* light crops are caught, **heavy crops (20 % and more) are not**, because a perceptual hash is not crop-invariant; that needs the embedding confirmation of Phase 4. *Limits of the measurement:* the negatives are 200 different scenes (no burst shots or near-identical takes), the video set is small (10 clips with slow-zoom motion made from photos), and recall is quoted at the chosen limits. The full table for 30 limit pairs is printed by `tools/test.sh swift "labeled set"`
- [x] **Detection never changes a file.** Engine test `finding_duplicates_changes_no_file` (every path, size, modification time and byte of the test tree identical after add, scan, hash, picture hash and rescan); the in-app self-test checks five files byte for byte around a review
- [x] **Cleanup moves exactly the confirmed files to the Trash and nothing else; cancelling changes nothing; a changed file is refused.** The guard (tests in `sa-engine/tests/duplicates.rs`): a review is required first; confirming accepts only ids inside the review (the kept copy, a stranger, an empty list, an unknown or used-up token are refused); every file is checked against the disk again right then (size, modification time, 16 KiB samples, not a symbolic link) and **one failing file refuses the whole action**; at least one copy that stays is verified; files on a drive that is away are refused; `cleanup_done` ignores ids that were not approved; cancelling forgets the review. Rust never moves a file; Swift moves only what Rust approved. **Real Trash, in the real app** (self-test): a file on a disk image goes to that drive's `.Trashes`, is byte-identical there, exactly one record leaves the library, rating and tag appear on the kept copy; one combined review moves one copy from each of two groups; **Undo restored both byte-identical**; a copy edited after the review was **refused** with a readable sentence and stayed put
- [x] **Hash job pauses on battery / heat, resumes after quit, idempotent after `kill -9`.** Tests: held while hot, held on battery with "Index only when plugged in", held by the user's pause, **stopped in the middle of a 48 MiB file with nothing stored**, finished after release; a quit and reopen finishes it with one job per file; **a child process killed with SIGKILL** in the middle of hashing 40 files: reopened (unclean exit detected, no database problem), every hash correct, one job per file, all done, files byte-identical
- [~] **Standard checks.** Clippy clean; 153 Rust tests, 38 Swift tests, 12 in-app self-tests; zero warnings; `grid-lint`, `audit-motion` pass; **42 layout files pass** (the Duplicates page and review are measured); light and dark snapshots of Exact Copies, Similar, ticked state, the review sheet and Settings ▸ Privacy reviewed. Performance, 250k library (the generator now marks the picture-hash pass finished, otherwise the app tries to hash files that do not exist): **idle CPU 0.01 %, scroll p99 5 ms at 15,000 pt/s, ready in 0.32–0.35 s, first grid ≤ 0.95 s, 134–138 MB** (earlier numbers: 0.26 s, ≤ 0.9 s, 105–115 MB; the extra background work and the larger job table cost about 70 ms and 20 MB). Opening the Duplicates page on 250k assets with 6,000 exact and 6,000 similar groups: **2.5 s the first time, then 15 µs** until the library changes. `tools/audit-network.sh` passes. **Not done: a human VoiceOver, Tab-order and Increase Contrast pass on the Duplicates page and sheet**

Left for later: a group the person has decided "is not a duplicate" cannot be dismissed yet (it will reappear); the review lists every file, which is slow to read for hundreds of groups.

---

## Phase 3 · Model and retrieval spikes (M0 remaining)

**Status (2026-11-07): candidates measured on public proxy sets; nothing selected, deliberately.** The owner's rule: *Phase 3 selects candidates, real creator-media tests validate them,
production adoption requires reproducible results, dependency and licence review, and hardware testing.* Decisions D1–D5 of 2026-11-07 are applied (list below). Write-ups:
`docs/research/phase3-model-spikes.md` (findings), `phase3-proxy-benchmarks.md` (datasets, ground truth, method, limits), `creator-media-evaluation.md` (D3 protocol), raw outputs in
`docs/research/phase3-results/`.

**Owner decisions applied**
- [x] **D1** Third-party runtime experiments, isolated: LiteRT-LM, whisper.cpp and WhisperKit built and run only inside `~/Library/Developer/SmartAsset/phase3/isolation` (`sandbox-exec`: no network, personal files denied, `HOME` redirected). Dependencies and build scripts read, versions/commits/checksums in `PINS.md`, no blanket Bash permission rule. **EmbeddingGemma2Swift / MLX Swift not built: it needs Apple's Metal Toolchain (system-level install, owner approval)**
- [x] **D2** Provisional modality-specific pass bars, hit@10 / MRR@10 / precision@10 retained, dataset composition, ground truth, query difficulty and method documented; no runtime finalised on a proxy set or an aggregate
- [~] **D3** Creator-media evaluation required before selection: protocol and validator written (`spikes/creator-eval`); **media and queries not supplied**
- [x] **D4** 16 GB accepted for comparisons (every number names the machine); **8 GB and 24–32 GB still required** before hardware or performance claims
- [x] **D5** Exact scan first; real-vector recall and latency measured; memory calculations verified against measurement

**Inputs needed before finishing:**
- [ ] Real creator media (D3): technical screen recordings, tutorials and long-form video, voiceovers, noisy recordings, music and sound effects, **English now (owner: English first; Hindi and Hinglish in a later phase)**, long recordings with moments, with annotated ground truth and hard negatives. **Not supplied**
- [x] Full Xcode installed (Xcode 27.2 in `/Applications`; `xcode-select` still points at the Command Line Tools, use `DEVELOPER_DIR`)
- [x] **Metal Toolchain installed** (owner approved 2026-11-07): build 27B47, `metal` 32023.922, sealed read-only cryptex from Apple's asset service, image SHA-256 recorded in `PINS.md`
- [ ] Access to an 8 GB and a 24–32 GB Apple Silicon Mac. **Not available; this Mac is a 16 GB M5**

### Build / measure (results go into PLAN.md §13.1, never estimated)
- [x] Research and confirm EmbeddingGemma 2: released 6 Oct 2026, **Apache 2.0** (plus a Prohibited Use Policy sentence), 740M parameters, text, image, video and audio in one 768-d space, MRL 512/256/128, 8K context; **bf16/f32 only, never f16**. **Neither Swift runtime embeds video**
- [x] EmbeddingGemma 2 on MLX Swift vs LiteRT-LM Swift: **owner chose MLX Swift (2026-11-07, PLAN §16)**; production approval still under the release gate. Comparison: **comparison complete on proxy data** for every listed criterion (`phase3-model-spikes.md` §2). MLX is 1.6–2× faster per image (62 against 101 ms), 6× faster for batched text, a tie on 5,000-image retrieval (hit@10 0.851 against 0.845) and buildable from reviewed source, but uses 2.7× the memory (1.2 GB against 0.44 GB), runs hotter, has no usable CPU path and comes from a one-maintainer package; LiteRT is lighter and steadier with a CPU fallback but slower, serial, and a closed ad-hoc-signed binary. Concurrent image throughput: LiteRT 10/s whatever the concurrency; MLX 16.5 to 19.1/s (**both below the Phase 4 gate of 20/s**). Vectors from the two are not interchangeable (sounds cosine 0.94). **Both binaries import sockets and process-spawning or URL-loading functions**: an enforced control (sandboxed helper without network entitlement, runtime audit) is needed whichever is chosen. Open before any selection: creator English media, an 8 GB result, binary reviews, a plan for the 20/s gate
- [~] 512 vs 768 dimensions (never 128): **measured on proxy sets** (COCO 5k, 25,000 queries): hit@10 0.845 / 0.842 / 0.833 / 0.763 at 768 / 512 / 256 / 128; f16 and int8 storage cost ≤ 0.001. **Final only after creator media.** Corpus size matters more than dimension: the same model scores 0.986 hit@10 on 500 images and 0.845 on 5,000
- [x] Vector storage cost: **measured and checked against resident memory at 250,000 vectors** (f16 366 / 244 MB, int8 184 / 123 MB at 768 / 512 d, matching the computed sizes to 0.1 MB; HNSW graph 174 B/vector measured against 137 computed; freed memory is not returned, so build from stored vectors). RAM is the constraint, not disk or the 3 % budget
- [x] HNSW vs exact scan (D5): **exact scan first.** On real vectors the exact int8 scan takes 173 µs at 20,000 × 768 d (about 2 ms extrapolated to 250,000) against a 150 ms budget, so HNSW is not introduced; where tried, HNSW ef ≥ 64 returned 99.7–99.8 % of the exact top-10 on real vectors. Not tested: real vectors at 250,000, filtered search on real vectors
- [~] Whisper (owner: **WhisperKit with quantised Large-v3 Turbo is the provisional preferred candidate**, whisper.cpp the alternative; **English first**): measured on LibriSpeech, an 8.3-minute English recording with 40 known sentence starts, and real Hindi (record only). WhisperKit Large: long-English WER 0.024, all 40 sentence starts found, median timestamp error 0.15 s; WhisperKit Small is close (0.028; 0.32 s) at 216 MB, so a tiered English default is a hypothesis to test on creator speech; whisper.cpp q5_0 (best of four configurations) WER 0.106, 34 of 40 found, timestamps 0.10 s with DTW. System-wide memory (3 runs): WhisperKit Large +1.0 GB, Small +0.65 GB, whisper.cpp q5_0 +1.3 GB, fp16 +2.1 GB; first-launch Core ML compile 47 s (Large) / 13 s (Small). **Energy not measured** (needs root: `sudo spikes/asr/energy_session.sh`); long-session thermals not measured. Real Hindi WER 0.30–0.35 (synthetic voices had overstated it)
- [~] Inference architecture (owner: **start in-process behind a provider interface that permits XPC**): interface and a child-process stand-in prototyped and measured with both runtimes (`phase3-inference-architecture.md`): no per-call cost within 2 ms, main-thread timing unchanged in either design, a `kill -9` of the model process contained (error in about 0.1 s, restart 0.4–1.1 s, app unharmed), app footprint 74/207 MB instead of 440/1,211 MB, grid scroll unchanged while the GPU embeds in another process. **Not measured:** real XPC, memory pressure, a sandboxed helper, real GPU frame pacing. Plan §6.9 stays open
- [~] Labeled retrieval test sets for every † feature with an agreed pass bar each (**English first**): protocol, validator (now also requiring a person's verdict on every annotated moment and a second reviewer on 20 %), `ingest.py` and an offline `review.py` page written; **authorized media from the owner pending**. Pass bars are confirmed only after the first creator-media results
- [~] Licences of chosen models and runtimes verified in `docs/LICENSES.md`: register updated (LiteRT binary findings, whisper.cpp, swift-argument-parser, CMake, test material); the final choice decides what ships

### Language scope (owner decision, 2026-11-07)
English is the first priority; more languages come later. Every gate in this roadmap is judged on **English** until the owner opens a later language phase. Hindi and Hinglish (plan §7.4, §10) are future gates, not current ones; multilingual measurements made so far (synthetic voices, FLEURS Hindi) are records, and **no multilingual support is claimed**.

### Release gate for any model runtime (owner decision, 2026-11-07)
No runtime is production-approved until **all** of these hold:
- [ ] Real creator-media retrieval tests pass (synthetic and public proxy results do not count)
- [ ] Modality-specific pass bars are met, per stratum
- [ ] Dependency and binary security reviews are complete (provenance, signatures, network behaviour of every binary). **MLX review done 2026-11-07** (`phase3-model-spikes.md` §2.1): every socket, `popen`/`system`/`dlopen` and `NSURLSession` import traced to unused code (ring backend, CPU JIT, Hugging Face client under `Tokenizers`); the trimmed build and the enforced no-network control are not built yet (need owner permission)
- [ ] Licence obligations are documented in `docs/LICENSES.md`
- [ ] Hardware limitations are clearly recorded: only the 16 GB M5 has been tested; **no support is claimed for 8 GB or 24–32 GB** until those machines are tested

### Validation gate
- [ ] Every decision above recorded in PLAN.md §13.1 / §16 with the measured numbers (findings recorded in §13.1 and §16; **runtime D6 made: MLX Swift; Whisper and XPC decisions are not made**)
- [ ] Creator-media sets pass their bars **per stratum** (D3), on at least 16 GB, with 8 GB and 24–32 GB recorded before hardware claims (D4)
- [ ] Pass bars agreed by the owner for each † feature
- [ ] No licence left "to verify" for anything Phase 4 or 5 will ship (LiteRT no longer ships; open: redistributing `mlx.metallib`)

---

## Phase 4 · Vector engine and visual search (M2)

### Build
- [~] `sa-vector` crate: **exact scan first (D5), HNSW not built.** f16 storage, normalising, per-asset best-row scoring, filter callback; vectors partitioned by model config; the index is derived from SQLite and rebuilt on demand. *Evidence:* 10 `sa-vector` tests (all 65,536 f16 patterns round-trip), engine test "vectors survive a restart and the index is rebuilt without the model". Atomic swap and a graph index are not built
- [x] Schema migration v3: `model_configs` and `embeddings` (f16 blobs) with model ID, version, modality, dims, preprocessing. *Evidence:* the existing upgrade-from-every-version test passes with it
- [~] Embedding work contract (`sa-providers`, bridge, `Workers/EmbeddingWorker`) + `Embedding` target with MLX Swift. Pictures from the thumbnail, videos from three frames (20/50/80 %). *Evidence:* 11 engine tests with a fake model. **Scene splitting and timestamps (S2) not built**
- [~] H5 model manager (owner's rules of 2026-11-09): pinned Hugging Face files only, downloaded only when the person chooses Download Model after seeing name, publisher, version, size and disk space; SHA-256 per file; HTTPS with redirects only to Hugging Face hosts; staging folder and atomic install into Application Support; Remove. *Evidence:* kit tests; opt-in self-test against Hugging Face (wrong checksum refused, 513.4 MB installed in 178 s, used, removed); `tools/audit-network.sh` and `tools/offline-check.sh` pass (`docs/research/model-download.md`). **Not done:** resume inside a file, switching models (one exists), Whisper models
- [~] H3 first-run model step: the Search page says search by meaning needs its model and its Set Up… button opens Settings ▸ Models; measured memory use is shown. **No memory-tier recommendation is claimed** (only a 16 GB Mac was tested)
- [~] S1 search by meaning (images and video frames, text query) and S12 blending with keywords (reciprocal rank fusion). *Evidence (140 picture tokens since 2026-11-08):* 5,058 files hit@1 0.54 / hit@5 0.78 / hit@10 0.85, 558 files 0.80 / 0.94 / 0.96; at the 0.70 cut no nonsense question answered at 558 files, 1 of 20 sentences and 1 of 15 single words at 5,058 (`docs/research/phase4-semantic-search.md`, "Accuracy"; rejected levers recorded there). *Earlier, 70 tokens:* in-app self-test "semantic search" on real COCO photos with human captions: 5,058 files hit@1 0.51 / hit@5 0.76 / hit@10 0.84 (Phase 3: 0.845), 558 files 0.79 / 0.94 / 0.96, 16 ms per question; words alone find none; per-model calibration (best match ≥ 0.70, band 0.08) rejects 19 of 20 nonsense queries at 5,058 files and 20 of 20 at 558 (`docs/research/phase4-semantic-search.md`). **Public photos only; not creator media; no pass bar agreed; rating/recency boost not built; audio not searched by meaning; video not measured**
- [x] **Premium visual pass (owner request 2026-11-08; native look, PLAN §16).** Gallery grid (square crops, whole columns, names off by default, hover lift), deeper picture backdrop, Search home heading + glass field + Newest Files, `Surface`/`Radius` tokens (`docs/design/DESIGN-SYSTEM.md`). *Evidence:* `tools/test.sh` (40 Swift tests), 14 of 14 in-app self-tests on the full MLX build (incl. "search page", "semantic search", "accessibility", "keyboard"), `tools/grid-lint.sh`, light and dark snapshots with the window active looked at. **Performance (250k, 15,000 pt/s, `APP_SEMANTIC=0`):** scroll p99 6.6 ms, max 7.1 ms, 0 ticks over 8 ms late; idle CPU 0.01 %; 150 MB after scroll; ready 0.40 s, first grid ≤ 1.0 s (the run before the pass: 143 MB, 0.22 s, ≤ 0.84 s; variance between runs not measured). **Tile-to-Viewer zoom added the same day:** opening a tile from the grid (Return, double-click) flies its picture into the Viewer (a short-lived panel, then a crossfade), skipped under Reduce Motion; self-test "viewer zoom" (a panel appears, the Viewer ends fully visible, no panel is left, reopening is clean) passes, 15 of 15 self-tests, a mid-flight snapshot `viewer-zoom-mid-*` looked at. Other ways to open the Viewer (menu, Inspector, list, Newest Files) appear without the zoom. **Not done:** a floating glass status pill, loading shimmer, a before/after slider for Similar copies (the last two animate per tile or per picture and need a bench first); hover lift is not covered by a snapshot (needs a pointer); the zoom is not measured for smoothness; keyboard-only and VoiceOver passes are manual
- [~] S2 moments inside videos: a video is described at **scene changes** (16 × 12 grey pictures at up to 96 instants, a new scene when the picture changes by ≥ 10 % and is ≥ 2 s after the last, 3 to 16 scenes, `SceneSelector`), each vector stored with its time (schema v5 `t_ms`); a video opened from a search starts at the closest moment; videos described before are described again by the backlog. *Evidence:* kit test of the selection rules, engine test (times kept, best scene named, pictures have none), self-test "video moments" (4-scene generated clip → 4 vectors at 0.5 / 3.5 / 6.5 / 9.5 s, the Viewer starts at the moment). **Also built (2026-11-09):** "▶ 0:42" on a video tile in results found by meaning (one engine call per page), a Moments row in the Inspector whose times open the Viewer there; self-test checks the Viewer, the tile and the row agree. **Not done:** timestamp accuracy on real recordings (**no real video measured**; the 10 % and 2 s limits are first guesses), clip-to-clip search
- [~] S4 OCR (Vision) with its own FTS table: **Text in pictures** built (2026-11-08). Vision `VNRecognizeTextRequest` (accurate, English) in `Workers/TextProcessor.swift` reads each picture from the original at up to 2,048 px and each video at three frames (20/50/80 %); text is tidied and stored in `asset_text` with an FTS5 table kept in step by triggers (schema v4), and keyword search matches it next to names, paths, tags and notes, so the blend with search by meaning includes it. A changed file is read again; a removed file or folder takes its text with it. *Evidence:* 6 engine tests with a fake reader (`sa-engine/tests/text.rs`), in-app self-test "text in pictures" (a slide, 30 pt small print on a 3,000 px label and a plain picture: both found by their words, nothing read in the plain one), 16 of 16 self-tests, 250k keyword search worst case 33 ms (text table empty in that bench). **Not done:** per-frame timestamps (with S2), showing the text in the Inspector or "why this matched" (S11), other languages, a real video in the self-test, creator media
- [~] S7 search by example and "More like this": the file's own description (every scene for a video) is the question; context menu, Inspector button, Library ▸ More Like This (⌥⌘F), a "Like …" token in the Search field. *Evidence:* engine tests (the file is never its own answer, filters apply, not-yet-described is told apart from nothing-like-it), self-test "more like this and why this matched": 100 COCO photos, 42 photos asked, precision@k 0.43 against 0.02 for chance (22×), first answer right 55 %. **Not done:** search by dropping a file or by a picture from outside the library, a cut-off on closeness (rank only, up to 200), sounds, **creator media**
- [~] S11 "Why this matched": the Inspector names where each typed word was found (name, folder name, tag, note with the words around it, text in the picture) and, only when search by meaning added the file, that it looks like what was described and for a video the closest moment. Placement uses the same keyword index as the search, one word and column at a time; the meaning line uses the search's own rule (best match ≥ minimum, file within the band). *Evidence:* engine tests, self-test (10 photos asked by their own caption: 9 added by meaning, none with placed words), snapshot `search-selected-*`. **Not done:** which part of a picture matched, labels (C1)
- [~] C1 scene/object labels, C2 media type labels. **C1 built:** 33 single-word labels ("beach", "dog", "night" …) embedded once by the model; a file shows a word when its own vector reaches the measured cut-off 0.68 (at most 5); Inspector "Shows" chips search the library for the word. Nothing stored: worked out from the vectors. *Evidence:* engine and unit tests; self-test "labels": on 500 COCO photos and 30 words, cut-off 0.66 → precision 0.73 / recall 0.90, **0.68 → 0.90 / 0.81**, 0.70 → 0.96 / 0.62; end to end through the engine, 157 labels shown for the 12 words a caption can confirm, **91 % confirmed**. **C2 not from the model:** measured, the model called 14 of 36 photos illustrations (best wording: 51 of 60 photos right, 5 of 12 illustrations), so Inspector "Content" uses facts: "Screen capture" (named as macOS and common tools name them), "Mostly text" (≥ 400 characters read in the picture); a camera stays its own row; otherwise nothing is claimed. **Not done:** labels as a stored filter or sidebar, illustration and chart kinds, creator media, multi-word labels (unmeasured)
- [x] A2 confirmation by embedding similarity: a file stays in a group of similar copies only if its picture is at least 0.90 alike (cosine; for a video, each scene's closest scene, averaged) to the group's first file; a file not yet described stays until it is; a model without a measured cut-off confirms nothing. *Evidence:* engine test (a "dog" picture with the same fingerprints leaves the "beach" group once described), unit test; self-test "copies by meaning" on 200 real photos: copies (resize, re-encode, brighter, less contrast, crops to 20 %) ≥ 0.934, grayscale ≥ 0.851, closest *different* photo ≤ 0.931; at 0.90, **99.8 % of 400 copies stay**. Also measured: 20 % crops, which fingerprints miss, score ≥ 0.937, so meaning could *find* them (not built: needs a neighbour search per file)
- [x] **UX redesign U1–U6 (owner request 2026-11-08): search-first.** The app opens on a Search page; Cleanup section; Kind scope bar; new tiles, inspector and Duplicates layout (PLAN §16, `docs/STORIES.md` U1–U6, `docs/design/SCREENS.md`). *Evidence:* `tools/test.sh` (40 Swift tests incl. scope, recent searches and sidebar round-trip), 13 in-app self-tests pass on the no-model build (new "search page"), "search page" and "semantic search" pass on the full MLX build, zero warnings in our sources, `tools/grid-lint.sh` passes, light and dark snapshots of every page looked at. **Performance re-measured after the tile change** (`tools/bench-grid.sh`, 250k synthetic library, 15,000 pt/s flick, `APP_SEMANTIC=0` so the model is not loaded): ready 0.22 s, first grid ≤ 0.84 s, 134 → 143 MB, idle CPU 0.01 %, scroll p99 7.2 ms (max 9.2 ms, 2 of 998 ticks more than 8 ms late). Scroll p99 is **a little worse than the 5 ms recorded in Phase 2** (inside the Phase 1 worst-case range of about 8 ms); the tile redraw is the likely cause and it stays on the Phase 6 watch list. With the model loaded (the shipping configuration) the same run shows ready 1.4 s, first grid ≤ 2.0 s, 430 → 729 MB, idle 0.02 %, scroll p99 6.8 ms: the extra time and memory are the search model (accepted in the 2026-11-07 runtime decision), not the redesign. The bench now selects All Files first because the app opens on Search. **Not done:** Space/⌘Y in Duplicates; S2, S7, S11 slots; keyboard-only and VoiceOver passes on the new pages are manual

### Validation gate
- [ ] **Each † feature passes its own real-world retrieval set** (S1, S2 incl. timestamp accuracy, S7, S12, C1, C2, A2). Model integration tests alone do not count.
- [~] Semantic / hybrid search < 150 ms at 250k assets; AI pass ≥ 20 images/s on 16 GB (8 GB figure recorded). *Measured:* 12–17 ms per question from 158 to 5,058 files; the exact scan at 250,000 vectors is 2 ms (Phase 3) but the whole blended search at 250k is **not measured**. **Images per second is not measured separately**: 142–152 ms per photo end to end including thumbnails and hashes; Phase 3's model-only 16.5–19.1/s stands; the gate is not met. **At 140 picture tokens (2026-11-08) the model alone takes 116 ms a picture (about 8.6/s sequential), further from the gate**; owner accepted up to about twice the time for accuracy
- [~] Re-embedding test: switch model, search stays available, swap is atomic. *Evidence (same model, new picture preparation, 2026-11-08):* engine test `while_the_library_is_described_again_search_still_finds_every_file`: the previous configuration answers for files not yet described again, each file is scored once, and the old vectors are deleted when every file has a new one. **A switch to a different model is not covered** (its vectors are not comparable, so search by meaning shows only described files until it finishes); that needs H5
- [x] Index rebuild test (exact scan, no HNSW files exist): the index lives in memory, is built from SQLite on first use, and gives identical results after a restart with no inference. *Evidence:* engine test "vectors survive a restart and the index is rebuilt without the model"
- [~] Browsing and thumbnails keep working with the model missing or crashing. *Evidence:* with no model announced no job exists and search is the keyword search (engine tests); the app **builds with zero warnings and runs without MLX** (`SA_NO_MLX=1`; its self-test for Smart Search passes and the semantic test reports "unverified: this build does not include the search model") and a model that fails to load only turns meaning-search off. A model *crash mid-run* is not tested (it runs in-process, PLAN §6.9). **Quitting while the model works is fixed and tested** (2026-11-09): 0 crashes in 30 launches after the fix against 10 in 12 before; self-tests "model under load" and the full suite pass
- [ ] Standard checks

---

## Phase 5 · Audio and voice (M3)

### Build
- [ ] Transcription contract + Swift TranscriptionWorker (chosen Whisper runtime); chunking long files; pause/resume/cancel
- [ ] Transcript segments with word timestamps; segment FTS table
- [ ] S3 search what was said; jump to the word in the Viewer
- [ ] S5 sound search (audio-window embeddings, kept separate from transcripts)
- [ ] S6 voice search: hold a hotkey, speak, release; the spoken query is shown and editable
- [ ] Viewer: transcript panel synced to playback

### Validation gate
- [ ] S3 and S5 pass their real-world sets (incl. Hinglish, music beds, noisy B-roll, 3-hour files)
- [ ] Jump-to-word lands on the word (timestamp error within the agreed bar)
- [ ] Voice query release → results < 1.5 s (16 GB+), < 2.5 s (8 GB)
- [ ] Transcription ≥ 5× real time (Turbo, 16 GB); no swap storms on 8 GB
- [ ] Standard checks

---

## Phase 6 · Hardening (M4.5)

### Build / test
- [ ] Kill-at-any-moment test: library and jobs survive `kill -9` mid-write, repeated
- [ ] Integrity: deliberate corruption → detection → recovery from WAL or last snapshot → derived indexes rebuilt
- [ ] Daily snapshot, weekly `integrity_check`, snapshot pruning
- [ ] Idempotency test for every job type (run twice, kill and resume mid-batch → identical, no duplicate records)
- [ ] Schema upgrade test from every older version
- [ ] Load test: 250k real assets and multi-TB media across drives
- [ ] Memory tuning and back-off verified on an 8 GB Mac
- [ ] Fuzzing for every path that reads files (scanner, probe input handling)
- [ ] Golden media set (~500 odd files) through the full pipeline
- [ ] Orphan thumbnail and filmstrip clean-up job

### Validation gate
- [ ] All tests above pass; file-safety test passes on the full golden set
- [ ] §8 targets met on 8 / 16 / 24 GB Macs (numbers recorded)

---

## Phase 7 · Private beta (MVP)

- [ ] App icon (bama `app-icon`), Developer ID signing, notarization, Sparkle updates
- [ ] Crash and hang reporting that stays local (opt-in export only)
- [ ] Acknowledgements screen generated from `docs/LICENSES.md`
- [ ] Beta testers across video, photo and audio creators; pricing interviews running in parallel

### Validation gate
- [ ] §8 targets met on testers' real libraries; crash-free sessions ≥ 99.9 %
- [ ] No open data-safety bug; every beta-reported bug triaged

---

## Phase 8 · Creator power (M5, 1.0)

- [ ] S8 example + text ("like this, but at night")
- [ ] S9 plain-words filters ("videos from last week longer than 2 minutes in 4K")
- [ ] C4 custom categories from 5–10 examples
- [ ] A4 best-take picker (bursts and repeated takes; sharpness, exposure, eyes open)
- [ ] A5 color palettes and color search
- [ ] V7 timeline view, V8 map view, V9 side-by-side compare (2–4)
- [ ] W2 drag a moment (trimmed temp clip, no re-encode where possible, auto clean-up)
- [ ] W3 FCPXML and Premiere XML export with markers

### Validation gate
- [ ] S8 and C4 pass their real-world sets; A4 and A5 measured against labeled sets
- [ ] Exported timelines open correctly in Final Cut Pro, Resolve and Premiere
- [ ] Temp clips are cleaned up; originals untouched
- [ ] Standard checks

---

## Phase 9 · Mac-wide access (M6, 1.0)

- [ ] M1 global quick-search panel (own hotkey, separate from App Intents), drag results out
- [ ] M2 menu bar item: progress, pause/resume/cancel, open quick search
- [ ] M3 Shortcuts actions via App Intents: search, open, tag, add to collection
- [ ] M4 Services / Finder right-click: "Add folder to SmartAsset", "Find similar in SmartAsset"
- [ ] H1 storage dashboard: space by drive and type, biggest files, space wasted by duplicates

### Validation gate
- [ ] Each entry point works from other apps; permissions asked only at first use
- [ ] Standard checks

---

## Phase 10 · Public release (M6 ship)

- [ ] Pricing decided from interview and pilot evidence (D3); only then plan billing
- [ ] Mac App Store feasibility (sandbox with the full feature set) decided
- [ ] Release checklist: licences, privacy statement, notarized build, update feed, support docs

### Validation gate
- [ ] All MVP and 1.0 features pass their gates; signed release shipped

---

## Change log for this roadmap

| Date | Change |
| --- | --- |
| 2026-11-05 | Created: remaining work after Phase 0 split into Phases 1–10 with validation gates |
| 2026-11-05 | Phase 1 worked: all automated gate items pass; manual items (editor drops, iCloud, NAS, VoiceOver/Tab/Increase Contrast) left for the owner |
| 2026-11-07 | Phase 3 started at the owner's request: research and vector-index measurements done; stopped at a permission boundary for the runtime comparisons |
| 2026-11-07 | Phase 3 continued under the owner's decisions D1–D5: LiteRT-LM, whisper.cpp and WhisperKit measured on proxy sets in an isolated workspace; exact scan confirmed on real vectors; MLX blocked on the Metal Toolchain; creator-media evaluation specified, media pending; no runtime selected |
| 2026-11-07 | Phase 2 started at the owner's request with Phase 1's manual checks still open, and worked: built and verified; two items partly met (heavy crops, human accessibility pass) |
