# SmartAsset — Product & Technical Plan

> **Status:** Features **LOCKED** · Technical decisions **DECIDED** (2026-11-04) · Pricing **under validation** · **Build started 2026-11-05** on the owner's instruction (see §16)
> **Rule:** the code follows this plan and the §13 milestone order. Changing a locked feature or decision needs an entry in §16 (Change log).

---

## 1. Pitch

A fast, private Mac app for creators' images, videos and audio, built as a Rust core with a native SwiftUI app. It indexes files where they already are and finds any asset, or any moment inside one, from a typed description, a spoken question, or an example file. All AI runs on the Mac.

## 2. Who it is for

All creators equally. No single persona outranks the others.

| Creator | Typical library | Main pain SmartAsset solves |
|---|---|---|
| Video creator (YouTube, Reels, TikTok, Shorts) | Hours of A-roll, B-roll, vertical clips, music | Finding one shot inside hours of footage |
| Photographer / designer | RAW, JPEG, exports, references | Duplicates, finding images by look or color |
| Podcaster / audio creator | Long recordings, SFX, music | Finding what was said, or a sound, across hundreds of files |

## 3. Global requirements

These apply to every feature and every milestone.

1. **Offline-first.** Everything works with no network. No mandatory cloud service, account or sign-in.
2. **Original files are never changed automatically.** SmartAsset must never modify, overwrite, rename, move or delete original files on its own. The single exception is duplicate cleanup (A3), and only when the user:
   - sees both files and their locations,
   - reviews which copy will be removed,
   - understands exactly which file will be moved to the Trash, and
   - explicitly confirms the action.

   Files are only ever moved to the Trash, never permanently deleted. Duplicate **detection** is read-only; **cleanup** is a separate, explicitly authorized action.
3. **Only folders the user adds.** Nothing on the Mac is indexed automatically. SmartAsset indexes only the folders the user explicitly adds (and their subfolders, minus any the user excludes). There are no default folders, no whole-disk scan, and no automatic adding of drives when they're plugged in.
4. **No extra copies.** Added folders are indexed in place; media is never copied into the app's library.
5. **Resumable and cancellable background jobs.** Every job can be paused, cancelled and resumed after quit or crash without corrupting state.
6. **Modular providers.** Media decoding and AI inference are replaceable workers behind batch contracts (§6.3), so they can be swapped without touching search, storage or UI.
7. **Tested on three memory tiers:** 8 GB, 16 GB and 24 GB+ Apple Silicon Macs.
8. **All model and library licences documented,** including redistribution requirements, before anything ships (see §10.3).
9. **Unplugged drives stay searchable.**
10. **Feels like a Mac app:** keyboard first, drag and drop everywhere, native menus, light and dark mode.
11. **Polite in the background:** indexing backs off on battery, heat and user activity.

## 4. Locked feature set

Each feature has an ID for user stories. Phase: **MVP** = first release (private beta) · **1.0** = public release. The phase split can be rebalanced without unlocking the feature.

### 4.1 Library

| ID | Feature | Phase |
|---|---|---|
| L1 | **User adds folders explicitly** (internal, external drive, NAS) via an Add Folder button, drag and drop onto the app, or the Finder right-click (M4). Indexed in place, never copied. Nothing is indexed until the user adds a folder | MVP |
| L1a | Manage added folders: list with size, file count and status; remove a folder (removes it from the index only, never touches the files); exclude subfolders | MVP |
| L1b | Access is granted per folder through the macOS folder picker (security-scoped bookmarks), so **no Full Disk Access** is ever requested | MVP |
| L2 | Live updates **inside added folders only**: new, changed or deleted files there are picked up automatically (FSEvents) | MVP |
| L3 | Files keep their tags, ratings and AI data when moved or renamed (content hash) | MVP |
| L4 | Unplugged drives stay searchable; the app names the drive to plug in to open a file | MVP |
| L5 | Per-folder include/exclude; pause, resume and cancel indexing; "index only on power" | MVP |
| L6 | Formats: images (JPEG, PNG, HEIC, WebP, GIF, TIFF, camera RAW), video (MOV, MP4, M4V; H.264, HEVC, ProRes), audio (WAV, AIFF, MP3, AAC/M4A, FLAC). Extra formats via the optional FFmpeg fallback (§7.3) | MVP |

### 4.2 Search (core)

Features marked † depend on EmbeddingGemma 2. Each one **is complete only when it passes its own real-world multimodal retrieval tests** on real creator media (§11). Basic model integration tests are required but never count as completion.

| ID | Feature | Phase |
|---|---|---|
| S1 † | **Semantic search** by description ("golden hour drone shot over water") across images, video and audio | MVP |
| S2 † | **Moments inside videos**: results point to the exact timestamp; click to play from there | MVP |
| S3 | **Search what was said**: multilingual transcripts of all video and audio; jump to the word | MVP |
| S4 | **Text inside images and video** (OCR): find the screenshot that says "invoice #4471" | MVP |
| S5 † | **Sound search**: "dog barking", "applause", "rain" in audio files and video soundtracks | MVP |
| S6 | **Voice search**: hold a hotkey, speak, release; the spoken query is shown so it can be corrected | MVP |
| S7 † | **Search by example**: drop an image, video clip or sound to find similar ones; "More like this" on any result | MVP |
| S8 † | **Example + text**: "like this, but at night" | 1.0 |
| S9 | **Plain-words filters**: "videos from last week longer than 2 minutes in 4K" become filters | 1.0 |
| S10 | Filter chips: type, date, duration, resolution, orientation, tag, rating, drive, color | MVP |
| S11 | **Why this matched**: shows the matching frame, transcript line, text found in the image, or label | MVP |
| S12 † | Keyword search over file names, tags, notes, transcripts and OCR text, **blended with semantic results** | MVP |

### 4.3 Auto-categorization

| ID | Feature | Phase |
|---|---|---|
| C1 † | Scene and object labels (beach, food, car, crowd, drone shot, talking head, product…) | MVP |
| C2 † | Media type: screenshot, screen recording, selfie, document/whiteboard, meme | MVP |
| C3 | Orientation and aspect: vertical 9:16, horizontal 16:9, square, 4:5 (from file dimensions, no AI) | MVP |
| C4 † | **Custom categories**: give 5–10 examples ("my product shots") and it finds the rest | 1.0 |

### 4.4 Organize

| ID | Feature | Phase |
|---|---|---|
| O1 | Tags, 1–5 star ratings, pick/reject flags, color labels, notes | MVP |
| O2 | Collections (manual) | MVP |
| O3 | **Smart collections**: saved searches and filters that update live | MVP |

### 4.5 Cleanup & analysis

| ID | Feature | Phase |
|---|---|---|
| A1 | **Duplicate detection, exact (read-only)**: finds copies with the same content anywhere. Detection never changes any file | MVP |
| A2 † | **Duplicate detection, near (read-only)**: resized, re-encoded, cropped or near-identical shots, grouped with a duplicate-confidence score | MVP |
| A3 | **Duplicate cleanup (separate, user-authorized action)**: review a group with the files side by side and their full locations; the user picks which copy to remove; a **confirmation screen** lists every file that will move to the Trash with its file size, modification date, full location and duplicate confidence; nothing happens until the user confirms. Trash only, never permanent delete | MVP |
| A4 | **Best-take picker**: group bursts and repeated takes; suggest the sharpest, best-exposed, eyes-open one | 1.0 |
| A5 | **Color search**: extracted palettes; search or filter by color | 1.0 |

### 4.6 Browse & view

| ID | Feature | Phase |
|---|---|---|
| V1 | Thumbnail grid that stays smooth with 250k assets; adjustable size | MVP |
| V2 | **Hover-scrub**: move the pointer over a video thumbnail to scrub it | MVP |
| V3 | Spacebar quick preview; arrow keys step through results | MVP |
| V4 | Viewer: image zoom; video player with frame stepping; audio waveform player | MVP |
| V5 | Inspector: camera, lens, resolution, codec, fps, duration, GPS, labels, tags | MVP |
| V6 | List view with sortable columns | MVP |
| V7 | **Timeline view** by capture date | 1.0 |
| V8 | **Map view** by GPS location | 1.0 |
| V9 | **Side-by-side compare** of 2–4 assets | 1.0 |

### 4.7 Workflow out to editors

| ID | Feature | Phase |
|---|---|---|
| W1 | Drag files into Final Cut Pro, Premiere Pro, DaVinci Resolve, CapCut, Figma, Canva, browsers, Finder | MVP |
| W2 | **Drag a moment**: dragging a video result gives just the matched sub-clip (a new temporary file, trimmed without re-encoding where possible, cleaned up automatically; the original is untouched) | 1.0 |
| W3 | **Editor timeline export**: selection as FCPXML (Final Cut, Resolve) and XML (Premiere) with markers at matched moments | 1.0 |

### 4.8 Mac-wide access

| ID | Feature | Phase |
|---|---|---|
| M1 | **Global quick-search panel**: a system-wide hotkey opens Spotlight-style search over any app; drag results straight out. Built as its own hotkey and panel, **separate from App Intents** | 1.0 |
| M2 | **Menu bar item**: indexing progress, pause/resume/cancel, open quick search | 1.0 |
| M3 | **Shortcuts actions** via App Intents: search, open, tag, add to collection | 1.0 |
| M4 | **Services / Finder right-click**: "Add folder to SmartAsset", "Find similar in SmartAsset" | 1.0 |

### 4.9 Housekeeping & setup

| ID | Feature | Phase |
|---|---|---|
| H1 | **Storage dashboard**: space by drive and type, biggest files, space wasted by duplicates | 1.0 |
| H2 | Missing-file repair: relink by content when a folder moved | MVP |
| H3 | First-run setup: the user picks the folders to add (nothing preselected, nothing scanned beforehand) → choose and download AI models (size and recommended choice for this Mac's memory shown) → grid appears at once while AI indexing continues with an ETA | MVP |
| H4 | Privacy page stating plainly that nothing leaves the Mac | MVP |
| H5 | **Model manager**: see installed models, download/remove models, switch Whisper size, trigger re-embedding after a model change | MVP |

### 4.10 Explicitly OUT (locked decisions, not oversights)

| Out | Note |
|---|---|
| **Face grouping / People** | Removed from version one by D7. If added later: Apple Vision for detection plus a properly licensed face-embedding model for local clustering; **no automatic identity naming** |
| Managed library / copying files in; SD card and phone import | Conflicts with "no extra copies" |
| Automatic discovery: whole-Mac scan, default folders (Pictures, Movies, Downloads), auto-adding plugged-in drives, "suggested folders" | Only user-added folders are indexed |
| Full Disk Access permission | Not needed; access is per added folder |
| Follow-up search refining ("only the vertical ones") | |
| Suggested tags | Could return after 1.0 |
| Projects and usage tracking | |
| Quality flags (blur, shake, clipped audio) | Sharpness/exposure scoring still exists inside A4 |
| Audio/music tools (BPM, key, loudness) | |
| Export presets / format conversion | |
| Captions/subtitle export | Cheap later since transcripts exist |
| License / rights tracking for user assets | |
| XMP sidecars, library backup/restore | |
| CLI / MCP for AI agents | |
| Any cloud feature | Offline-first, on-device only |
| Editing media | We hand off to real editors |
| Billing, licence keys, trial enforcement | Not implemented until pricing is validated (D3) |
| Intel Macs, Windows, Linux | Apple Silicon only |
| Documents, fonts, 3D files | Images, video, audio only |

## 5. Key user flows

1. **First launch:** welcome → add the folders to index (nothing preselected) → pick AI models (recommended for this Mac's memory, sizes shown) → grid appears immediately with thumbnails; AI indexing continues in the background with progress and ETA.
2. **Find B-roll:** global hotkey → hold-to-speak "city at night with neon signs" → results show matching *moments* → hover-scrub to confirm → drag the moment into Final Cut.
3. **Find a quote:** type "we hit 100k subscribers" → transcript hit in a 2-hour stream → click → player opens at 1:12:43.
4. **Find a sound:** drop a whoosh SFX → similar sounds across the SFX library and video soundtracks.
5. **Clean up:** Storage dashboard → "38 GB in duplicates" (detection only, nothing changed) → open a group → see both files with their locations → pick the copy to remove → confirmation screen (size, modification date, location, duplicate confidence for each file) → confirm → that copy moves to the Trash.
6. **Pick the best take:** open a burst or repeated-take group → best take suggested → compare side by side → flag pick.
7. **Switch models:** Settings → Models → choose Large-v3 Turbo → download → app re-transcribes in the background, cancellable.

## 6. Architecture

### 6.1 Split of responsibilities (D1)

| SwiftUI app owns | Rust core owns |
|---|---|
| All UI: windows, grid, viewer, inspector, quick panel, menu bar | File discovery and watching |
| macOS integration: permissions, security-scoped bookmarks, Services, global hotkey, drag and drop | Indexing orchestration and the job manager (queues, priorities, pause/resume/cancel, retries) |
| App Intents / Shortcuts | Metadata model and persistence interfaces (SQLite, vector index, thumbnail cache) |
| Native frameworks: AVFoundation, ImageIO, Vision, Speech | Search: query parsing, filters, retrieval, ranking fusion, "why matched" |
| **Model inference** (initially): EmbeddingGemma 2 via MLX Swift or LiteRT-LM Swift | **Work contracts** for embedding, transcription, OCR and media analysis: typed job batches out, typed results back (§6.3) |
| Swift workers that pull job batches from Rust and do the native work end to end | Model version and embedding configuration on every indexed record; re-embedding jobs; vector index build and atomic swap |
| | Duplicate detection (read-only), file-safety enforcement, crash recovery |
| Transcription inference by a Swift transcription worker (WhisperKit, first prototype) | **Transcription job lifecycle and orchestration**; a Rust Whisper worker can fulfil the same transcription contract |

### 6.2 Shape

```
┌────────────────────────────── SwiftUI app ───────────────────────────────┐
│ UI · menu bar · quick panel (global hotkey) · App Intents · Services     │
│ Workers (pull batches from Rust, do all native work locally):           │
│   MediaWorker (AVFoundation/ImageIO/CoreGraphics) · OcrWorker (Vision)   │
│   EmbeddingWorker (MLX Swift | LiteRT-LM Swift)                          │
│   TranscriptionWorker (WhisperKit)                                       │
│   (inference workers may move to an XPC service, see §6.9)               │
└──────────────▲─────────────────────────────▲──────────────────▲─────────┘
               │ commands / queries          │ next batch ↔     │ events
               │                             │ results          │
          ═════╪═════════════ documented native bridge (UniFFI) ╪═════════
┌──────────────┴──────────────────── Rust core ─────────────────┴──────────┐
│ discovery/watch · job manager · indexer pipeline · metadata · search     │
│ ranking · duplicate detection · file safety · recovery                   │
│ storage: SQLite (source of truth) + FTS5 · vector index (derived) · thumbs│
└──────────────────────────────────────────────────────────────────────────┘
```

**Rules:**
- Swift owns the Mac experience. Rust owns the application engine. AI and media frameworks are replaceable workers.
- The search, ranking and storage code never depends on a model runtime. It sees only vectors plus their model/config identity.
- The UI never talks to storage directly. It goes through the Rust core API.
- Nothing crosses the bridge one item at a time, and large image, video or audio data never crosses it at all.

### 6.3 Native bridge: pull-based batches

**Model:** Rust owns the job queue; Swift workers **pull** work instead of Rust calling back into Swift per item.

1. A Swift worker calls `next_batch(kind, max_items)` (e.g. "embed up to 100 keyframes").
2. Rust returns job IDs with **file paths, time ranges and parameters only**, never media bytes.
3. The worker reads and decodes the files itself, runs Vision or the model, and keeps every buffer on the Swift side.
4. The worker calls `submit_results(batch)` once with vectors, OCR text, transcripts, metadata or typed per-item errors.
5. Rust commits the batch in one transaction, updates indexes and reports progress.

That's two bridge calls per batch. Cancellation: each batch carries a cancellation token; Rust can revoke a batch, and the worker checks between items.

- **Bridge:** UniFFI, confirmed in M0. The API is kept small: commands, queries, `next_batch`, `submit_results`, event stream.
- **Documented** in `docs/BRIDGE.md` (written in M0): every exported type and function, threading model, memory ownership, error mapping, cancellation, versioning.
- **Async:** bridge calls are async on both sides; SwiftUI updates happen on the main actor only.
- **Errors:** typed errors cross the bridge; nothing panics across it.
- **Files:** security-scoped bookmarks are resolved by Swift, which starts access before handing paths to Rust or workers.

### 6.4 Rust workspace

| Crate | Responsibility |
|---|---|
| `sa-core` | Domain types (Volume, Asset, Moment, Tag, Collection, SmartCollection, Label, ModelConfig), IDs, errors |
| `sa-providers` | Work contracts: batch request and result types for embedding, transcription, OCR and media analysis, with test fakes. A contract can be fulfilled by a Swift worker (over the bridge) or a Rust worker |
| `sa-transcribe` (optional) | Rust Whisper worker for the transcription contract, built only for the M0 benchmark and kept only if it wins |
| `sa-store` | SQLite schema (source of truth, incl. every vector), migrations, repositories, FTS5 keyword index, integrity checks |
| `sa-vector` | USearch HNSW indexes **derived from SQLite**, partitioned by model config and modality; rebuild, atomic swap, adaptive filtered search |
| `sa-jobs` | Job manager: persistent priority queues, the job contract (§6.6), batch leasing for workers |
| `sa-index` | Pipeline: discover → fingerprint → probe → thumbnail → analyze → transcribe → embed → commit |
| `sa-search` | Query parsing, filters, keyword + vector retrieval, rank fusion, "why matched" |
| `sa-watch` | FSEvents, drive mount/unmount, volume identity by UUID |
| `sa-engine` | Composition root: wires store, scanner, watcher, job manager and search into one API with no FFI, so the whole pipeline is tested in pure Rust with fake workers (added 2026-11-05) |
| `sa-ffi` | The bridge surface exported to Swift |

`#![forbid(unsafe_code)]` everywhere except where the bridge requires it, and that code is isolated in `sa-ffi`.

**Concurrency split:**

| Runtime | Used for | Never used for |
|---|---|---|
| **Tokio** (small runtime) | Async bridge calls, event stream to Swift, file-watch events, timers, job leasing | Hashing, decoding, ranking or any CPU-heavy work |
| **Rayon** (bounded pool) | BLAKE3 hashing, perceptual hashing, color palettes, vector index builds, brute-force vector scans | Waiting on I/O |
| **Dedicated threads** | SQLite writer (one writer, many readers in WAL mode) | |

Every queue between stages is bounded, so memory stays flat under load. Concurrency adapts to memory pressure and thermal state.

**Diagnostics:** `tracing` in Rust and `OSLog` in Swift, one shared request/job ID across both, local rotating logs.

### 6.5 Swift package layout

| Module | Responsibility |
|---|---|
| `SmartAssetApp` | App entry, windows, scenes, settings |
| `Features/*` | Library, Search, Viewer, Cleanup, Storage, QuickPanel, MenuBar |
| `Intents` | App Intents for Shortcuts |
| `Workers` | Batch workers: AVFoundation/ImageIO/CoreGraphics media, Vision OCR, embedding inference, transcription (WhisperKit) |
| `InferenceService` (if §6.9 chooses XPC) | XPC service hosting the model workers |
| `CoreBridge` | Generated bindings + thin Swift wrappers |

### 6.6 Indexing pipeline rules

- **Two passes:** a fast browse pass (files, metadata, thumbnails) makes the library usable in minutes; the AI pass follows in the background. **Thumbnails and browsing never depend on AI inference**: if a model crashes or is missing, the library still browses.
- **Priority lanes:**
  1. Assets visible on screen
  2. Newly added assets
  3. User-requested work (e.g. analysing a dropped example file for S7)
  4. Background backlog
  5. Duplicate analysis and maintenance
- **Job contract:** every job has persistent state, a cancellation token, a retry policy with backoff, a checkpoint, resource limits (memory, time), an error class (transient / file-corrupt / unsupported / model-failure / permission) and **idempotent execution**, so re-running a job after a crash never creates duplicate records.
- **Resumable and cancellable:** quit, crash or cancel resumes from the last checkpoint.
- **Versioned:** every embedding stores model ID, model version, modality, dimensions and preprocessing config. A model change re-embeds only affected records into a new index partition; the old partition serves search until the new one is complete, then they are **swapped atomically**.
- **Isolated:** a corrupt file fails its own job and never stalls the pipeline. A model failure fails the batch, not the app.
- **Polite:** background priority, pause on battery (setting), throttle under heat, memory pressure or user activity.

### 6.7 Search pipeline

Parse query → metadata filters → keyword search and vector search in parallel → fuse rankings (reciprocal rank fusion) → boost by rating and recency → group moments under their file → return with "why matched" evidence.

**Adaptive filtered vector search.** HNSW gets slow and misses results when a filter is very narrow ("vertical, last week, this drive"). So per query:
- **Broad or no filter:** HNSW search with the filter applied during traversal.
- **Narrow filter** (matching set under a threshold, tuned in M0, roughly ≤ 20k vectors): exact brute-force scan of just the matching vectors on Rayon. At 512 dims this is a few milliseconds and always exact.

### 6.8 Storage

**SQLite is the single source of truth.** Every other store can be rebuilt from it.

| Data | Where | Rebuildable? |
|---|---|---|
| Volumes, assets, metadata, tags, ratings, notes, collections, smart collections | SQLite | Source of truth |
| Jobs and checkpoints | SQLite | Source of truth |
| Transcripts with word timestamps, OCR text, labels | SQLite (+ FTS5) | Source of truth |
| **Every embedding vector** (f16 blob) with its asset ID, moment time range, modality and model config | SQLite | Source of truth |
| Model configurations | SQLite | Source of truth |
| HNSW vector indexes | `vectors/`, one per model config × modality | **Yes**, from SQLite vectors in minutes, no re-inference |
| Thumbnails and previews | `thumbs/`, sharded by hash | Yes, from original files |
| Models | `models/` | Yes, re-download |

`~/Library/Application Support/SmartAsset/` holds all of it plus `logs/`. Media files are never stored here.

- **Integrity:** SQLite `quick_check` on launch after an unclean exit; full `integrity_check` weekly in the background; on failure, recover from the WAL or restore the last good snapshot, then rebuild derived indexes.
- **Budget:** index + thumbnails ≤ 3% of indexed media size. Storing vectors in both SQLite and HNSW costs extra; M0 measures whether quantized HNSW (int8) plus f16 in SQLite fits the budget.
- **No database server:** no Qdrant, PostgreSQL or similar; everything is embedded.

### 6.9 Inference isolation (XPC): M0 experiment, not yet a decision

**Idea:** run EmbeddingGemma 2 and Whisper in a separate XPC service instead of inside the app process.

| Possible benefit | Known cost to measure |
|---|---|
| A model-runtime crash can't take down the app | Process start-up and model load time |
| Models unload by ending the process, so memory is truly freed | Moving inputs and results between processes (use file paths + shared memory/IOSurface, never copies) |
| Browsing and inference never compete inside one process | **File access:** the service must read media from user-chosen folders; passing folder permission into it is fiddly, and harder under the App Store sandbox |

**Decide in M0** by measuring crash recovery, memory returned after unload, and per-batch overhead against **in-process inference with controlled model lifetimes** (load on demand, unload after idle, unload under memory pressure). Pick whichever is better on 8 GB Macs. The batch contract (§6.3) is the same either way, so this choice doesn't affect the Rust core.

### 6.10 Not used in the product

Electron, Tauri, Python runtime, Node.js, PostgreSQL, MongoDB, Qdrant, Docker, any cloud backend. None is needed for the product's requirements.

## 7. AI & media stack

### 7.1 Models (all on-device, downloaded separately from the app installer)

| Job | Model / framework | Runs in |
|---|---|---|
| Shared embeddings for text, images, video, audio (all † features) | **EmbeddingGemma 2** (Google; 740M params; text 270M + vision 170M + audio 300M encoders; 768-dim, can be shortened to 512/256/128; **benchmark 512 vs 768, never default to 128**, which loses measurable retrieval quality). Context fits ~58 video frames or ~5.5 min audio, so video is split into scenes and audio into windows | Swift: **MLX Swift** first, benchmarked against **LiteRT-LM Swift** (D6) |
| Transcripts with word timestamps (S3) and voice queries (S6) | **Whisper Large-v3 Turbo** preferred; **Whisper Small** fallback (D5). Independent of EmbeddingGemma 2 | Behind the transcription contract. First prototype **WhisperKit** (Swift), benchmarked against a Rust-compatible Whisper; winner chosen by §7.4 |
| Text in images/video (S4) | Apple Vision OCR | Swift |
| Eyes open, sharpness, exposure (A4) | Vision face landmarks + classic image metrics | Swift (Vision), Rust (metrics) |
| Color palettes (A5) | k-means in a perceptual color space | Rust |
| Plain-words filters (S9) | Rule-based parser; English filter words first, semantic part multilingual | Rust |

**Categorization (C1, C2, C4):** each label has a short text description. Asset embeddings are compared with label embeddings, and labels above a tuned threshold are applied. Custom categories use the average embedding of the user's examples. No training.

**EmbeddingGemma 2 requirements (D6):**
- Text, image, audio and video modalities where the runtime supports them; any unsupported modality is reported, never silently skipped.
- One shared embedding dimension and compatible preprocessing across modalities.
- Model version and embedding configuration stored with every indexed record.
- Re-embedding supported after a model or config change.
- No model-runtime dependency in the search UI or storage layer.

**Embedding records: many per asset, never one per file.**

| Asset type | Embeddings stored | Linked to |
|---|---|---|
| Image | One image embedding (more for very large or panoramic images, as tiles) | Asset |
| Video | One per scene / sampled keyframe | Asset + time range |
| Audio (incl. video soundtracks) | One per audio window (sound events, music, ambience) | Asset + time range |
| Speech | Transcript segments with word timestamps (text, searched by keyword and by text embedding) | Asset + time range |

**Transcripts and sound embeddings are kept separate.** "Find where I said *subscribe*" (speech) and "find applause" (sound event) are different problems with different indexes.

### 7.2 Model choice by memory tier (D5)

| Mac memory | Whisper default | Other options | EmbeddingGemma 2 |
|---|---|---|---|
| 8 GB | **Small** | Turbo allowed with a memory warning | Full multimodal; shorter batches |
| 16 GB | **Large-v3 Turbo** | Small | Full multimodal |
| 24 GB+ | **Large-v3 Turbo** | Small; larger models available for evaluation | Full multimodal; larger batches |

The user can change the model any time in the model manager (H5).

### 7.3 Media handling (D4)

| Job | Choice |
|---|---|
| Primary decoder for video, audio, thumbnails, keyframes, playback, trimming | **AVFoundation** + VideoToolbox (hardware) |
| Images incl. HEIC and RAW | ImageIO |
| Fallback for unsupported formats | **FFmpeg, optional**, behind the same media contract (a separate worker). Not bundled until the LGPL/GPL and codec redistribution check passes (§10.3) |
| Scene splitting for "moments" | Frame difference + embedding change on sampled frames |
| Content hash | BLAKE3, plus a quick partial hash for change detection |
| Perceptual hash (near-duplicates) | dHash/pHash on images and keyframes, confirmed by embedding similarity |

### 7.4 Transcription provider decision

**Rule:** decided on measured Mac performance, not language preference.

- **Rust owns** the transcription job lifecycle: queueing, priorities, chunking long files, pause/resume/cancel, retries, storing transcripts and word timestamps.
- **Any implementation** that fulfils the transcription contract (§6.3) can be plugged in, whether in Swift or Rust.
- **Candidates:** WhisperKit (Swift, prototyped first) vs a Rust-compatible Whisper implementation (e.g. whisper.cpp via `whisper-rs`).
- **Both run the same test set:** the golden media set's speech files across languages, accents, Hinglish, music beds, noisy B-roll, 3-hour recordings.

| Criterion | How it is measured |
|---|---|
| Transcription accuracy | Word error rate per language against reference transcripts |
| Timestamp quality | Word-start error in ms against hand-aligned references; jump-to-word lands on the word |
| Memory consumption | Peak and steady memory on 8 GB, 16 GB and 24 GB+ Macs |
| Speed | Real-time factor for Small and Large-v3 Turbo |
| Thermal behaviour | Sustained 1-hour run: throttling, fan, temperature, battery drain |

The winner becomes the default; the other is dropped unless it is clearly better on one memory tier.

## 8. Performance targets

Measured on **8 GB, 16 GB and 24 GB+** Apple Silicon Macs with a 250k-asset library.

| Metric | Target |
|---|---|
| Cold launch to usable grid | < 1 s |
| Keyword search | < 100 ms |
| Semantic / hybrid search | < 150 ms |
| Grid scroll | Display refresh rate, no dropped frames |
| Hover-scrub | < 50 ms per frame |
| Voice query: release key → results | < 1.5 s (16 GB+), < 2.5 s (8 GB) |
| Idle CPU | ~0% when not indexing |
| Memory (not indexing) | < 500 MB |
| Memory (indexing, 8 GB Mac) | No swap storms; pipeline backs off under memory pressure |
| Browse pass | ≥ 500 files/s on internal SSD |
| AI pass: images | ≥ 20 images/s on 16 GB; record the 8 GB figure in M0 |
| AI pass: video/audio | Analysis ≥ 10× real time; transcription ≥ 5× real time (Turbo, 16 GB) |
| Crash-free sessions | ≥ 99.9% |

Exact 8 GB and 24 GB+ numbers are set from M0 benchmarks.

## 9. Platform

- **macOS 14 Sonoma or later** (D2). Newer-OS APIs only behind availability checks.
- **Apple Silicon M1 or later only.** Intel is outside the initial target.
- Direct download first (Developer ID, notarized, Sparkle updates). Mac App Store later if sandboxing allows the full feature set.

## 10. Business, licences & validation

### 10.1 Pricing (D3) — not final, no billing built yet

Hypotheses to test:

| Option | Price |
|---|---|
| Early access | $49 one-time |
| Pro | $79 one-time |
| Alternative | $59 / year |

### 10.2 Validation plan

- Creator interviews across all three groups (video, photo, audio).
- Paid pilot commitments (pre-orders or deposits) for each option.
- Pricing is decided from that evidence, then billing gets planned.

### 10.3 Licence register

Kept in `docs/LICENSES.md` (to be written in M0) and checked before every release.

| Component | Licence (to verify) | Redistribution notes to confirm |
|---|---|---|
| EmbeddingGemma 2 | Reported Apache 2.0 | Confirm on model card; attribution requirements |
| Whisper (Small, Large-v3 Turbo) | MIT | Weights downloaded separately |
| WhisperKit | Check (reported MIT) | Converted model weights and their source licence |
| whisper.cpp / whisper-rs (benchmark candidate) | Check (reported MIT) | |
| MLX Swift / LiteRT-LM | Check | |
| FFmpeg (optional) | LGPL or GPL depending on build | Dynamic linking, codec patents, which build flags |
| UniFFI, SQLite, usearch, other crates | Check each | Generated as part of the build |

## 11. Quality strategy

- Rust: clippy (pedantic) as errors; no `unwrap()` outside tests; `unsafe` only in `sa-ffi`.
- Swift: strict concurrency; no force-unwraps in production code.
- Unit and property tests for parsing, hashing, ranking, migrations, job state machine.
- **Provider fakes:** search, storage and indexing are tested with fake providers, without any model runtime.
- Fuzzing for every path that reads files.
- **Golden media set:** ~500 real files (odd codecs, corrupt files, huge RAWs, 3-hour videos, silent audio, many languages) through the full pipeline.
- **Real-world multimodal retrieval tests** (completion gate for **every** † feature):
  - **Not enough:** model integration tests (model loads, returns vectors of the right shape, runs on each modality). Those are required too, but they never count as completion.
  - **Required:** each † feature has its own labeled test set built from **real creator media** (real footage, screen recordings, voiceovers, music beds, SFX, noisy B-roll, mixed languages incl. Hinglish), with realistic queries a creator would type or say.
  - Coverage: text→image, text→video moment (correct timestamp, not just correct file), text→sound, image→image, clip→clip, sound→sound, example+text, near-duplicate pairs, category labels, custom categories.
  - Measured as recall@10 and MRR (plus timestamp accuracy for moments and precision/recall for categories and near-duplicates), against a pass bar set per feature in M0.
  - A † feature is **complete only when its real-world set passes its bar**. After that, no merge may push it below the bar.
- **Bridge tests:** cancellation, errors and concurrency across Rust↔Swift.
- **Worker conformance tests:** every worker for the same contract (e.g. WhisperKit vs Rust Whisper, MLX vs LiteRT-LM) passes the same test suite.
- **File-safety tests:** indexing, detection, search and re-embedding never change a single byte, name or location of any original file (checked by hashing the golden set before and after). Cleanup moves only the confirmed files, only to the Trash.
- Performance tests on all three memory tiers against §8.
- Kill-at-any-moment test: library and job state survive `kill -9` mid-write.
- Every schema version upgrades from every older version.
- Re-embedding test: switch model config, re-embed, search stays available throughout; the index swap is atomic.
- **Idempotency test:** run every job type twice, and kill-and-resume mid-batch; the result is identical with no duplicate records.
- **Index rebuild test:** delete all HNSW indexes; they rebuild from SQLite with identical search results and no model inference.
- **Integrity test:** corrupt the database deliberately; detection and recovery work as designed in §6.8.
- **Load test:** 250k assets and multi-TB media, measured against §8.
- **Swift tests:** XCTest for UI state, navigation and permission flows.

## 12. Design & UX process

The UI is designed with the **bama** design skills, which target native SwiftUI Mac apps and match D1. Goal: smooth, native-feeling flows where indexing never blocks browsing and no step needs an unnecessary dialog.

### 12.1 Which skill is used when

| Skill | Used for | When |
|---|---|---|
| `bama:user-stories` | Turn the §4 feature IDs into prioritized stories with checkable acceptance criteria (`docs/STORIES.md`) | After this plan is Final, before M1 |
| `bama:ux-design` | UX pass per feature: names, flow, where it opens (inline, popover, sheet, window), every state, wording, hover help, accessibility | Before coding **every** story that adds a screen, action or text |
| `bama:mac-design` | Native macOS rules: sidebar, toolbar, menus, search field, keyboard, type, color, dark mode; Liquid Glass on newer macOS with a clean fallback on macOS 14 | Designing and reviewing every window, panel and settings screen |
| `bama:design-system` | Accent color, design tokens, consistent spacing and motion; `docs/design/DESIGN-SYSTEM.md` | Once, before the first UI milestone; updated as screens are added |
| `bama:layout-grid` | Alignment and spacing checks for the thumbnail grid, inspector, rows and sheets | After every UI change that touches layout |
| `bama:app-icon` | App icon | Before the private beta |
| `bama:build-and-verify` | Light and dark snapshots of every screen before calling a UI change done | After every UI change |

`bama:design-kit` (a fully custom look) is **not** planned: SmartAsset uses the native Mac look plus its own accent and tokens. It can be revisited if testing shows the app needs a stronger brand.

### 12.2 States every screen must design for

Empty library · first indexing (browse pass done, AI pass running) · indexing paused · drive offline · file missing · no results (with suggestions) · model not downloaded · model switching / re-embedding · permission not granted · error. These come from the global requirements: offline-first, resumable jobs, unplugged drives.

### 12.3 Flow rules

- Search is reachable from everywhere in one keystroke (⌘F in the window, global hotkey outside it).
- Results appear as you type; nothing waits behind a "Search" button.
- Long work (indexing, re-embedding, duplicate scan) runs in the background with progress in the window and menu bar, never in a blocking modal.
- Destructive actions (Trash in A3) always show a review step with what will happen and how to undo it (Trash restore).
- Every action has a keyboard shortcut and a menu item.
- Motion is short and consistent (taken from the design system), and respects Reduce Motion.

### 12.4 Design deliverables before M1 code

1. `docs/STORIES.md` (user stories)
2. `docs/design/DESIGN-SYSTEM.md` (tokens, accent, motion)
3. `docs/design/SCREENS.md`: screen map and UX pass for every MVP screen (main window, search, viewer, inspector, cleanup review, onboarding, model manager, settings)

## 13. Milestones

| Milestone | Goal | Exit criteria |
|---|---|---|
| **M0 · Spikes** (throwaway) | Prove the risky parts | UniFFI bridge prototype of the **pull-based batch model** (`next_batch` / `submit_results`, cancellation, no media bytes across the bridge), written up in `docs/BRIDGE.md`; **XPC vs in-process inference** measured per §6.9; **512 vs 768 embedding dimensions** on the retrieval test sets; **vector storage cost** (f16 in SQLite + int8 HNSW) against the 3% budget; HNSW vs brute-force threshold for filtered search; SwiftUI 250k-thumbnail grid + hover-scrub + drag-out; **EmbeddingGemma 2 on MLX Swift vs LiteRT-LM Swift** (speed, memory, modality coverage, relevance on real creator media); **WhisperKit vs a Rust-compatible Whisper**, Small and Large-v3 Turbo, on 8/16/24 GB, scored per §7.4; FFmpeg licence check; `docs/LICENSES.md` first version; **real-world retrieval test sets** collected and labeled for every † feature, with a pass bar agreed per feature |
| **M1 · Library** | See everything, fast | L1–L6, V1–V6, O1–O3, H2, H3, H5 |
| **M2 · Visual search** | Find images and video moments | S1, S2, S4, S7, S10–S12, C1–C3 (after retrieval tests pass) |
| **M3 · Audio & voice** | Find what was said and heard | S3, S5, S6 |
| **M4 · Cleanup** | Duplicates | A1–A3, H4 |
| **M4.5 · Hardening** | Make it trustworthy before anyone else uses it | 250k-asset load tests, memory tuning on 8 GB, kill/recovery, idempotency, index-rebuild and integrity tests all pass; file-safety tests pass on the full golden set |
| **MVP · Private beta** | All MVP features polished | §8 targets met on 8/16/24 GB Macs with beta testers' real libraries; pricing interviews running |
| **M5 · Creator power** | 1.0 features | S8, S9, C4, A4, A5, V7–V9, W2, W3 |
| **M6 · Mac-wide + ship** | Public 1.0 | M1–M4, H1, pricing decided, signed release |

### 13.1 Status (2026-11-05)

**M1 · Library: built** (see `docs/STORIES.md` for each feature and how it was verified). 118 Rust tests, 24 Swift tests, clippy clean,
zero Swift warnings, light/dark snapshots of every screen reviewed.

**M0 · Spikes: partly done.** Results are recorded as measured, or marked *pending*; nothing is estimated.

| M0 item | Result |
| --- | --- |
| UniFFI bridge, pull-based batches, cancellation, no media bytes | **Done.** Confirmed: UniFFI 0.32 works in Swift 6 mode with async calls, typed errors and a callback interface; 300 concurrent calls and 50 cancelled calls are safe; documented in `docs/BRIDGE.md` |
| SwiftUI 250k-thumbnail grid, hover-scrub, drag-out | **Grid measured** (NSCollectionView over a paged Rust result set; 93–121 MB, p99 timer lateness 3.3 ms at 15,000 pt/s). SwiftUI's own lazy grids were not benchmarked: NSCollectionView was chosen from the start for 250k. Hover-scrub and drag-out are implemented but *not yet exercised* |
| SQLite + FTS5 query speed at 250k | **Done.** Keyword 0.1–14 ms, filtered 3–15 ms, newest-first 20 ms, page of 120 tiles 0.15 ms (release, 16 GB Mac) |
| Browse-pass throughput | **Done.** 10,700 files/s first scan, 327,000 files/s unchanged rescan, 500-file folder rename relinked in 156 ms |
| HNSW vs brute-force threshold, vector storage cost (f16 + int8) | **Measured (2026-11-07), synthetic vectors for speed and real EmbeddingGemma 2 vectors for recall (decision D5).** Exact int8 scan: 1.0 ms at 250,000 × 512 d (synthetic, 10 cores); on real vectors 173 µs at 20,000 × 768 d (about 2 ms extrapolated to 250,000). Against the 150 ms budget the exact scan does not fail, so **HNSW is not introduced**; where tried, HNSW ef ≥ 64 returned 99.7–99.8 % of the exact int8 top-10 on real vectors. **Memory checked against measurement at 250,000 vectors:** f16 and int8 sizes match to 0.1 MB; the HNSW graph is 174 B/vector, not the computed 137; freed f32 memory is not returned to the OS (build the index from stored vectors, never from a resident f32 copy). RAM, not disk, is the constraint (184 MB int8 at 768 d, 123 MB at 512 d per 250,000 vectors). Details: `docs/research/phase3-model-spikes.md` §4 |
| 512 vs 768 dims | **Measured on proxy sets only (2026-11-07), not final.** COCO text→image over 5,000 images / 25,000 captions: hit@10 768d 0.845, **512d 0.842**, 256d 0.833, 128d 0.763; caption→caption 0.754 / 0.754 / 0.752 / 0.736. 512 costs 0.3 points, 128 costs 8. Final only after the creator-media sets (decision D3). Details: `docs/research/phase3-model-spikes.md` §3 |
| EmbeddingGemma 2 facts | **Confirmed (primary sources).** Apache 2.0 + Prohibited Use Policy sentence; 740M (270M text, 170M vision, 300M audio); 768-d, MRL 512/256/128; 8K context (image 280 tokens, video 140 per frame, audio 25 per second); **bf16/f32 only, f16 breaks it**; **no video input in either Swift runtime** |
| EmbeddingGemma 2 on MLX Swift vs LiteRT-LM Swift | **Compared on every criterion on proxy data (2026-11-07); no runtime selected (owner).** Image 62 ms (MLX) against 101 ms (LiteRT), batched text 2.9 against 17.2 ms per text, 5,000-image retrieval hit@10 0.851 against 0.845 (a tie), memory 1.2 GB against 0.44 GB, MLX CPU path unusable, throughput 19.1/s against 10/s (**both below the 20/s gate**), vectors not interchangeable, both binaries import networking functions. Details and the open conditions: `docs/research/phase3-model-spikes.md` §2 |
| WhisperKit vs a Rust Whisper (Small, Large-v3 Turbo; 8/16/24 GB) | **WhisperKit (quantised Large-v3 Turbo) is the owner's provisional preferred candidate; whisper.cpp the alternative; English first.** On an 8.3-minute English recording WhisperKit Large reaches WER 0.024 with all 40 sentences found (timestamps median 0.15 s); whisper.cpp's best configuration WER 0.106, 34 of 40 found (timestamps 0.10 s); WhisperKit Small is close (0.028), so an English tier is a hypothesis. System-wide memory +1.0 GB (Large) against +1.3 GB (whisper.cpp q5_0); first launch compiles 47 s. Energy and long-session thermals not measured; 8 GB and 24 GB not tested (not available). `whisper-rs` is archived: the Rust option is whisper.cpp with our own binding |
| XPC vs in-process inference (§6.9) | **Start in-process behind a provider interface (owner); decision open.** Prototype measured with both runtimes: no per-call cost beyond 2 ms through a child process, unchanged main-thread timing, a killed model process contained, app memory 74/207 MB instead of 440/1,211 MB. Real XPC, memory pressure and sandboxing untested. `docs/research/phase3-inference-architecture.md` |
| FFmpeg licence check; `docs/LICENSES.md` | **Partly.** Register written; Rust crates verified from `cargo metadata` (permissive; UniFFI is MPL-2.0); model and Swift-package licences still *to verify* |
| Real-world retrieval test sets and pass bars for every † feature | **Pending.** Needs real creator media; these gate M2 |
| Tests on 8 GB / 16 GB / 24 GB+ Macs | **16 GB only so far** |

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| EmbeddingGemma 2 not fully supported (all modalities) in MLX Swift or LiteRT-LM Swift | High | M0 benchmark of both; the batch contract allows another runtime, including a Rust one, later |
| EmbeddingGemma 2 quality on creator footage unproven | High | Real multimodal retrieval tests gate † features |
| Bridge overhead or threading bugs between Rust and Swift | High | Pull-based batches, no media bytes across, small API, dedicated bridge tests, documented contract |
| Narrow filters make vector search slow or miss results | Medium | Adaptive search: brute-force scan below a tuned threshold (§6.7) |
| Vector index corrupted or out of sync | Medium | SQLite holds every vector; indexes rebuild in minutes without inference |
| XPC inference service can't read user-chosen folders cleanly | Medium | M0 experiment; in-process inference with controlled model lifetimes is the fallback |
| 8 GB Macs run out of memory while indexing | High | Small Whisper default, smaller batches, back-off on memory pressure, tested in CI on 8 GB |
| Indexing multi-TB libraries takes days | High | Two-pass indexing, priority lanes, visible ETA |
| FFmpeg licensing or codec patents | Medium | Optional, unbundled until checked |
| Pricing hypotheses wrong | Medium | Interviews and paid pilots before building billing |
| Index size at 250k assets | Medium | Shortened, quantized vectors; limit keyframes per minute |
| Drive identity edge cases | Medium | Identify volumes by UUID |

## 15. Next steps

1. Review this plan and mark it **Final**.
2. Design deliverables (§12.4) with the bama skills, in parallel with M0.
3. Run M0 spikes; record results in this plan (runtime choice for EmbeddingGemma 2 and Whisper, bridge choice, memory-tier numbers).
4. Write `docs/BRIDGE.md` and `docs/LICENSES.md`.
5. Start M1 story by story, each with a `bama:ux-design` pass before coding and `bama:build-and-verify` after.

## 16. Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft |
| 2026-11-04 | Features locked: all-creator audience, index in place, on-device only, multilingual, EmbeddingGemma 2 as the shared embedding model, 250k-asset scale. |
| 2026-11-04 | Technical decisions D1–D7 made. D1: Rust core + SwiftUI shell, native bridge, global hotkey separate from App Intents. D2: macOS 14+, M1+. D3: pricing hypotheses only, no billing yet. D4: AVFoundation primary, FFmpeg optional fallback behind an abstraction. D5: Whisper Large-v3 Turbo / Small by memory tier, separate model downloads. D6: Rust owns the embedding provider interface, Swift runs inference (MLX Swift vs LiteRT-LM Swift). **D7: face grouping (O4) removed from version one; person filter and People flow removed.** Global requirements added (§3). Model manager (H5) added to support model selection and re-embedding. |
| 2026-11-04 | Design & UX process added (§12): UI designed with the bama skills (user-stories, ux-design, mac-design, design-system, layout-grid, app-icon, build-and-verify); native look, no custom design kit; design deliverables required before M1 code. |
| 2026-11-04 | Original-files principle defined precisely (§3.2): nothing changed automatically; detection read-only; cleanup a separate user-authorized action with a confirmation screen (size, modification date, location, duplicate confidence). Transcription: Whisper independent of EmbeddingGemma 2; Rust owns the job lifecycle; `TranscriptionProvider` implementable in Swift or Rust; WhisperKit prototyped first and benchmarked against a Rust Whisper on accuracy, timestamps, memory, speed and thermals (§7.4). |
| 2026-11-05 | Only user-added folders are indexed (§3.3, L1, L1a, L1b, L2, H3): no default folders, no whole-disk scan, no auto-adding of drives, no Full Disk Access. Automatic discovery added to the out-of-scope list. |
| 2026-11-05 | Name confirmed: **SmartAsset**. Retrieval gate confirmed for **every** † feature: completion requires passing per-feature real-world multimodal retrieval tests on real creator media; model integration tests alone never count (§4.2, §11). |
| 2026-11-05 | **Build authorized** by the owner ("build according to the plan"). The "no code until Final" gate is lifted for M0 and M1 scope; implementation follows §13 order. Pricing (D3) stays under validation and no billing is built. Results of M0 spikes that need hardware or media this project does not have yet (8 GB / 24 GB Macs, real creator media, model weights) are recorded as **pending**, never estimated. |
| 2026-11-05 | **Build decisions (no locked feature changed).** (1) New crate `sa-engine` (composition root, §6.4). (2) Volume mount/unmount events and security-scoped bookmarks are handled in Swift and reported to Rust (`volume_mounted`, `sync_volumes`), consistent with D1; `sa-watch` covers FSEvents only. (3) L3 uses a quick hash (size + three 16 KiB samples) with a name/mtime tie-break; the full-content BLAKE3 arrives with A1, because reading every byte of a multi-TB library would defeat the fast browse pass. (4) iCloud-only placeholder files are skipped, so a scan can never trigger a download. (5) Symlinks, hidden items and opaque bundles (`.photoslibrary`, `.fcpbundle`, …) are not indexed. (6) Adding a parent of an already-added folder merges the child in, keeping its tags and ratings. (7) The grid is `NSCollectionView` over a paged Rust result set. (8) Swift tests run as an executable target because `swift test` cannot work with Command Line Tools only; with only CLT the app builds against the macOS 26 SDK (see `docs/BRIDGE.md`). (9) S10 filter chips were built in M1 (planned M2) because smart collections (O3) need them. (10) The Models tab lists the catalog and the D5 memory-tier recommendation but offers **no download** until the M0 model spikes are done. |
| 2026-11-07 | **Phase 2 build decisions (no locked feature changed).** (1) The full-content BLAKE3 is computed only for files that share size and quick hash with another present file; the A1 groups are (size, full hash). (2) A2 ships as **A2-lite**: a 64-bit difference hash and a 64-bit DCT hash per picture (three keyframes per video), made by the Swift worker from the existing thumbnail, matched in Rust (`sa-dedupe`) at DCT ≤ 10 and difference ≤ 12 bits, chosen on a labeled set of 200 real photographs (no false pair at these limits; heavy crops are not caught). Embedding confirmation stays in M2. Plain pictures (black frames, solid colours, smooth gradients) are never matched. Audio is exact-only. (3) **Rust issues cleanup approvals; Swift moves files.** A review is required; confirming accepts only files in the review; each file is re-checked against the disk (size, time, samples, not a link); one failure refuses the whole action; the kept copy is verified. (4) A3 additions: ratings, tags, notes and collections of a removed copy move to the copy that stays; the app offers Undo, which puts the files back from the Trash. (5) Settings gets a Privacy tab (H4) and the claim "no network connections" is checked by `tools/audit-network.sh`. (6) Errors shown to people use the error's own sentence, not UniFFI's debug text. |
| 2026-11-07 | **Language priority (owner): English first; other languages later.** English is the first-priority language for transcription (S3) and retrieval. Hindi and Hinglish, which §7.4, §10 and §11 name in the golden sets, move from *required now* to *future phases*: they stay on the roadmap as later gates, **no Hindi or Hinglish support is claimed or promised**, and the Phase 3 and Phase 4 gates are judged on English. Consequences: (1) the creator-media set (D3) requires English in every stratum now; Hindi and Hinglish items are collected when that phase starts (the validator no longer demands them); (2) the Whisper size choice is judged on English first, so the earlier "Small is not the default" rests on multilingual use and is reopened for an English tier: on one 8-minute English recording WhisperKit Small matched Large-v3 Turbo closely (WER 0.028 against 0.024) while being 3× smaller, to be confirmed on creator English before any default is set; (3) the multilingual results already measured (synthetic and FLEURS Hindi) are kept as records, not as claims. |
| 2026-11-07 | **Owner decisions on the outstanding Phase 3 items (no locked feature changed).** (1) **Hardware coverage:** 16 GB M5 results are accepted for Phase 3. **No 8 GB Mac and no 24–32 GB Mac is available**; every Phase 3 number is a 16 GB M5 number and says so. **No support is claimed for untested configurations**: the memory tiers of §7.2, the 8 GB figure for the Phase 4 images/s gate and any performance claim for other chips or memory sizes stay *unverified* until those machines are tested. (2) **Metal Toolchain installation approved** (build 27B47, recorded in `PINS.md`); experiments stay isolated. (3) **No embedding runtime is selected**: MLX Swift and LiteRT-LM are compared on text, image and audio, cross-modal retrieval, GPU/CPU consistency, concurrent image throughput, memory and thermals, cold start, and security and dependency provenance; neither is adopted until the comparison is complete. (4) **Whisper:** WhisperKit with quantised Large-v3 Turbo is the *provisional* preferred candidate and the primary prototype; whisper.cpp stays as the alternative; Small is not the default for multilingual use. Before adoption: system-wide memory, energy, thermals, timestamp accuracy, multilingual accuracy and first-launch experience. (5) **Inference architecture: start in-process**, behind a provider interface that allows moving to XPC; isolation, responsiveness, memory pressure and reliability are benchmarked before the process architecture is final (§6.9 stays open). (6) **Creator-media evaluation** needs owned or explicitly permissioned media with manually validated ground truth and timestamps; synthetic and public proxy results are never promoted as real-world retrieval validation. (7) **Release gate:** no runtime is production-approved until real creator-media retrieval tests pass, modality-specific bars are met, dependency and binary security reviews are complete, licence obligations are documented, and hardware limits are recorded. |
| 2026-11-07 | **Phase 3 continued under the owner's decisions D1–D5 (no locked feature changed; two gates flagged).** (1) D1: LiteRT-LM, whisper.cpp and WhisperKit were built and run only in an isolated workspace (no network, no personal files, pinned and checksummed); not production adoption. (2) D2/D3: pass bars are provisional; proxy and creator-media results are reported separately; **no runtime is selected on proxy data**. Creator-media protocol and validator written (`docs/research/creator-media-evaluation.md`); media not yet supplied. (3) D4: results are 16 GB only; 8 GB and 24–32 GB runs remain required before hardware or performance claims. (4) D5: exact scan first, confirmed on real vectors; HNSW not introduced; memory calculations verified, graph overhead corrected from 137 to 174 B/vector. (5) **Flagged, not changed:** the Phase 4 gate *AI pass ≥ 20 images/s on 16 GB* is not met by LiteRT-LM measured sequentially (9.9/s); and **a 10× larger corpus drops text→image hit@10 from 0.986 to 0.845**, so every pass bar must state its corpus size. (6) The LiteRT-LM binary is ad-hoc signed and imports networking functions: a network audit or source rebuild is required before it can ship. (7) MLX Swift is unmeasured until the Metal Toolchain is installed (owner approval). |
| 2026-11-07 | **Phase 3 findings (no locked feature changed).** (1) EmbeddingGemma 2 confirmed from primary sources; the §7.1 description holds. Added constraints: **inference in bf16/f32 only (f16 breaks the model)**, and the model card's Prohibited Use Policy sentence goes in the licence register and Models tab. (2) **Neither Swift runtime embeds video**, so video features are planned as per-keyframe image embeddings plus the soundtrack's audio embedding, to be proven by the retrieval tests. (3) **§6.7 revised:** measured on a 16 GB M5, an exact int8 scan of 250,000 vectors takes 1 ms, so Phase 4 ships the exact scan and defers HNSW (needed only beyond about 1 M vectors); the "HNSW above about 20k vectors" rule is dropped because a filtered graph walk is slower than a scan below about 20 % selectivity. Memory (516 MB per million vectors at 512 d), not disk or the 3 % budget, is the sizing constraint. (4) `whisper-rs` is archived; the Rust Whisper candidate is whisper.cpp. (5) Runtime, Whisper and XPC decisions remain open. |
| 2026-11-07 | **Owner waives the Phase 3 validation gate for starting Phase 4 (no locked feature changed).** Phase 4 development begins on MLX Swift (D6) before creator-media tests, the 8 GB and 24–32 GB runs, and the trimmed-build / no-network hardening are done. **What this does and does not waive:** it lets development proceed; it does **not** approve anything for release. The release gate of 2026-11-07 (real creator-media tests per stratum, pass bars agreed, binary and dependency review, licences, hardware limits) still applies to shipping, and until it is met every Phase 4 retrieval result is *unvalidated* and is described that way in the app and the docs. The earlier ruling that Smart Search stays keyword-only until Phase 3 closes is lifted by this entry. Accepted risks, stated so they are not forgotten: MLX's unused network- and process-capable code is linked into development builds (PLAN §16 entry above, `phase3-model-spikes.md` §2.1); quality on creator media is unmeasured; the 20 images/s gate is unmet (16.5–19.1/s). |
| 2026-11-07 | **Embedding runtime chosen (owner): MLX Swift (D6).** EmbeddingGemma 2 runs on MLX Swift, not LiteRT-LM, on the measured comparison (image 62 vs 101 ms, batched text 2.9 vs 17.2 ms, retrieval a tie, buildable from reviewed source). Accepted costs: 1.2 GB resident against 0.44 GB, no usable CPU path, a one-maintainer Swift package. **This chooses the runtime, not its production approval:** the release gate still holds (creator-media tests, per-stratum pass bars, binary security review, licences, hardware limits). The owner also ruled that **Phase 3 is completed before semantic search goes into Smart Search** (S13 stays keyword-only until then). Open for MLX specifically: remove or lock down the network- and process-capable code the build links (Hugging Face download client via `swift-transformers`, the distributed ring backend, the CPU JIT), and a plan for the 20 images/s gate (measured 16.5–19.1/s). LiteRT-LM items (binary provenance, network audit) are closed as not shipping. |
| 2026-11-05 | Architecture review adopted: **SQLite is the single source of truth** incl. every vector; HNSW indexes derived and rebuildable, partitioned by model config × modality, swapped atomically (§6.8). **Pull-based batch bridge** replaces per-item provider callbacks; no media bytes cross the bridge (§6.3). Full job contract: idempotent, error classes, resource limits; user-request priority lane (§6.6). Tokio/Rayon/thread roles defined; OSLog + tracing (§6.4). Adaptive filtered vector search (§6.7). Many embeddings per asset; transcripts separate from sound embeddings; 512 vs 768 benchmark, never 128 (§7.1). XPC inference isolation as an M0 experiment (§6.9). Excluded tech listed (§6.10). Integrity, idempotency, rebuild, load and XCTest added (§11). M4.5 Hardening milestone added. |
| 2026-11-08 | **UX redesign: search-first (owner: "full rethink", search by meaning is the core and gets its own page; no locked feature added or removed).** (1) **S13 changes from an in-window box to a Search page** that is the start page; ⌘F is Search (inside the current folder, collection or tag when pressed on one), ⌘K is Search Everywhere; the toolbar search field and the palette are gone. (2) **Sidebar:** Search first; Library = All Files and Missing; the kind rows leave the sidebar and become a Kind scope bar over every page of files and over Search results; Duplicates moves under a new **Cleanup** section. (3) **Grid tiles:** badges follow the picture, label, flag and status share one capsule, a rating shows on hover or selection (View ▸ Show Ratings on Thumbnails keeps it on), selection is an accent ring plus a name capsule. (4) **Duplicates (A3):** groups list with the chosen group’s copies side by side (the literal "files side by side" of A3), Keep / Move to Trash per copy, one **Review** button; the guard and the confirmation screen (size, modified, location, match) are unchanged. (5) The Search page says **Preview** beside search by meaning, per the 2026-11-07 waiver. Slots for S2, S7 and S11 are designed but not built. |
| 2026-11-08 | **Premium visual pass (owner: "UX is best developed, only UI needs to be more premium"; native look kept, no custom design kit, no locked feature changed).** A deeper backdrop behind pictures (`Surface.content`), a gallery grid (square crops that fill the row, 8 pt between pictures, names off by default, 2 pt hover lift; View ▸ Crop Thumbnails to Squares and Show File Names bring back the earlier look), a Search home with a large heading, an accent wash, a Liquid Glass field (macOS 26+; tinted fill on 14 and 15) and a Newest Files strip, softer radii (`Radius`), and a tile-to-Viewer zoom (a short panel carries the tile’s picture into the Viewer; off with Reduce Motion). Chrome (sidebar, toolbar, sheets, inspector) stays Apple’s. |
| 2026-11-08 | **Search accuracy pass (owner: "best accurate search"; decisions on 2026-11-08).** (1) **Picture budget 70 → 140 tokens** (owner: up to about twice the indexing time). COCO 5k: hit@1 0.537 → 0.566, hit@10 0.851 → 0.868; 74 → 116 ms per picture (model only). New configuration `embeddinggemma2-mlx-q8-768-soft140-v1`; calibration 0.70 / 0.08 kept after re-measuring. The **20 images/s gate moves further away** (about 8.6/s for the model alone); flagged, not waived. (2) **Re-describing the library keeps search whole:** vectors of the previous configuration of the same model answer for files not yet described again, then are deleted (part of the "swap is atomic" gate item). (3) **Rejected after measuring:** pictures from originals instead of the 512 px thumbnail, "a photo of …" query wording, pseudo-relevance feedback. (4) **Hub correction from the user's own searches is not built** (owner): it helps by 0.4–3.3 points with 100–5,000 past searches but pushes a photo down when the user has searched for it before in other words. (5) **S4 Text in pictures built:** Vision on this Mac, English first, pictures from the original at up to 2,048 px, videos at three frames; the words join the keyword search; kept until the file changes; listed on the Privacy tab. All results are on public photos or generated pictures, **not creator media**; the release gate is unchanged. Details: `docs/research/phase4-semantic-search.md`, "Accuracy". |
| 2026-11-09 | **S2, S7 and S11 built (no locked feature changed).** (1) **More Like This (S7):** a file's own vectors are the question (a video asks with every scene); ranked, no cut-off, at most 200; the Search page shows it as a "Like …" token. (2) **Why This Matched (S11):** words are placed with the keyword index itself and listed only when every word is placed; the meaning line is shown only when search by meaning added the file, by the same rule as the search. (3) **Moments (S2):** videos are described at scene changes (16 × 12 grey pictures at up to 96 instants; new scene at ≥ 10 % change and ≥ 2 s after the last; 3 to 16 scenes) with each scene's time (schema v5); this replaces the fixed 20/50/80 % frames, and videos described earlier are described again. The 10 % and 2 s limits are **first guesses, not measured on real recordings**. (4) A crash at quit found while testing this is fixed (next entry). |
| 2026-11-09 | **Crash at quit fixed (no locked feature changed).** 39 of 40 MLX crash reports had the main thread in `exit()` while the search model was still evaluating. Quitting now waits for the model: `EmbeddingModel.close()` refuses new calls and waits for running ones, `AppModel.shutdown()` waits for a model that is loading, Quit during launch goes through shutdown, and the self-test exits through shutdown. Before: 10 crashes in 12 launches; after: 0 in 30, a full self-test run 19 of 19, accuracy unchanged. A rare main-thread crash in the runtime's main-executor check (4 reports in 4 days, two at sleep or wake) is **not explained and not changed**. Self-tests that need the app in front now report UNVERIFIED when another app keeps it in the background. Details: `docs/research/phase4-semantic-search.md`, "Crashes at quit". |
| 2026-11-09 | **A2, C1, C2 and the rest of S2 (no locked feature changed).** (1) **A2:** similar-copy groups are confirmed by meaning at 0.90, announced by the model with its calibration (`copy_match`); measured on 200 photos (99.8 % of copies stay). (2) **C1:** labels are a fixed list of 33 single words, cut-off 0.68 measured on 500 COCO photos (precision 0.90, recall 0.81); computed on demand, not stored. (3) **C2 changed from plan:** the plan said "label embeddings vs asset embeddings" for media type; measured, the model could not tell photos from illustrations, so C2 uses facts about the file (screen-capture names, text read in the picture, camera) and claims nothing otherwise. (4) **S2:** matched moment on result tiles and a Moments row in the Inspector. (5) More Like This re-measured with full ground truth: 500 photos, precision 0.57 against 0.02 for chance, first answer right 70 %. Public photos and generated pictures only; creator media still pending. |
| 2026-11-09 | **Model downloads (owner's rules; changes the Privacy claim).** Hugging Face is the only source, and only pinned, verified files (one repository at one commit, 11 files with SHA-256); a download starts only when the person chooses Download Model after seeing name, publisher, version, size and disk space; HTTPS, redirects only to Hugging Face hosts, staging folder, atomic install into Application Support; no telemetry, analytics, cloud inference, automatic downloads or update checks. **The Privacy tab no longer says "no network connections"**: it says SmartAsset connects only when the person chooses Download Model, and only to Hugging Face. The app loads models only from Application Support. Offline operation after install is tested with internet connections denied by the OS. Details: `docs/research/model-download.md`. |

