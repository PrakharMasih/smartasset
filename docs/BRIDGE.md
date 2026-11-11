# The Rust ↔ Swift bridge (plan §6.3)

UniFFI 0.32 in proc-macro mode. Rust crate `sa-ffi` is a thin skin over `sa-engine::Engine`. Swift gets generated bindings
(`Sources/CoreBridgeGenerated/sa_ffi.swift`, never edited) plus `Sources/CoreBridge` (hand-written, typed helpers).
`tools/gen-bridge.sh` builds the static library and regenerates the bindings. Generated files are build output and are git-ignored.

## Rules

1. **Small and coarse.** Commands, queries, `next_media_batch` / `submit_media_results`, an event stream. No per-item callbacks.
2. **No media bytes cross.** Rust hands workers *paths and parameters*. A worker reads the file, writes its thumbnail to the path
   it was given, and returns numbers and text.
3. **Async everywhere that touches storage.** Every such method is `async` on the Swift side and runs on a Rust blocking thread.
   Only pure, constant-time calls are synchronous (`ResultSet.count()`, `idAt`, `thumbPath`, `isBatchRevoked`, `setConditions`).
4. **Typed errors.** `BridgeError` has `NotFound`, `Invalid`, `Database`, `Io`, `Cancelled`, `SchemaTooNew`, `Corrupt`, `Refused`,
   `Internal`. Nothing panics across the bridge: a Rust panic inside a call becomes `Internal`.
5. **`unsafe` lives only in `sa-ffi`** (UniFFI's generated scaffolding). Every other crate is `#![forbid(unsafe_code)]`.

## Surface

| Group | Calls |
| --- | --- |
| Lifecycle | `openEngine(options, listener)`, `start()`, `shutdown()`, `openInfo()` |
| Queries | `search(query) → ResultSet`, `summaries(ids)`, `assetDetail(id)`, `paths(ids)`, `stats()`, `thumbPath`, `filmstripPath` |
| Result set | `count()`, `idAt`, `idsIn(offset, limit)`, `indexOf(id)`, `allIds()`, `summaries(offset, limit)` |
| Organize | rating, flag, colour label, notes, tags (add/remove/rename/delete), collections, smart collections |
| Folders | `addFolder`, `removeFolder`, `setFolderEnabled`, `setExcludes`, `relocateFolder`, `updateBookmark`, `listFolders`, `listVolumes`, `syncVolumes`, `volumeMounted`, `volumeUnmounted`, `rescan` |
| Indexing control | `pauseIndexing`, `resumeIndexing`, `cancelIndexing`, `reindexUnfinished`, `setConditions`, `setIndexOnlyOnPower`, `prioritize`, `progress` |
| Worker contract | `nextMediaBatch`, `submitMediaResults`, `isBatchRevoked`, `heartbeat`, `releaseBatch`, `requeueMedia` |
| Perceptual-hash contract | `nextPerceptualBatch`, `submitPerceptualResults` (same batch, lease, revoke, heartbeat and release calls as the media contract) |
| Duplicates | `duplicates() → exact and similar groups, progress`; read-only |
| Cleanup (A3) | `planCleanup(groupKey, removeIds)`, `approveCleanup(token, confirmedIds) → files that may be trashed`, `cancelCleanup(token)`, `cleanupDone(token, trashedIds)` |
| Test hooks | `matchPerceptual(items, maxP, maxD)`, `defaultNearDuplicateLimits()` (the engine's matcher as a pure function, for the labeled-set measurement) |
| Events (Rust → Swift) | `libraryChanged(structural)`, `thumbnailsReady(ids)`, `foldersChanged`, `duplicatesChanged`, `progress` (now with `dedupeRemaining`), `notice` |

The search query types (`SearchQuery`, `Filters`, `Sort`, enums) are declared *remote* from `sa-core`, so Swift sees the very
types smart collections store as JSON. Output records (`AssetSummaryDto`, `FolderDto`, …) use plain `i64` ids.

## Pull-based batches

```
Swift worker                           Rust
   │  nextMediaBatch(maxItems) ───────►│ lease up to N jobs (lane order, drive online, folder enabled, file present)
   │◄───────── tasks: path, thumbPath, │   a lease token + expiry guard every job; throttle (batch size, parallelism)
   │           thumbRev, size, mtime   │   comes from the pause/battery/thermal/memory policy
   │  …decode, write thumbnail…        │
   │  isBatchRevoked(batchId) between items (cheap, synchronous)
   │  heartbeat(batchId) while busy ───►│ extends leases
   │  submitMediaResults(batchId, …) ─►│ ONE transaction: complete / fail (class + backoff) / release
   │◄──────── SubmitReport ────────────│ results for a changed file or a revoked batch are discarded
```

Guarantees (each has a test, `core/crates/sa-engine/tests/pipeline.rs` and `Sources/SATests`):

- **Idempotent.** Submitting a batch twice commits nothing the second time. Enqueueing a job twice makes one row.
- **Crash-safe.** A batch whose worker dies loses nothing: leases expire (and are reset at launch) and the jobs run again.
- **Stale-proof.** If the file changed after it was leased, its result is discarded and the job runs again.
- **Isolated.** A corrupt file fails its own job (`FileCorrupt`/`Unsupported`/`Permission` are final; `Transient` retries with
  backoff up to 3 attempts) and never stalls the queue.
- **Cancellable.** `cancelIndexing` revokes outstanding batches; workers see it between items; late results are dropped.

## Duplicates, picture hashes and cleanup

Two more jobs use the same queue (`kind` = `hash`, `phash`): the full-content hash runs **inside Rust** (a background thread leasing
through the manager; it needs no decoder), the perceptual hash is a second pull contract for the Swift worker (the task carries the
original's path and the thumbnail's path, the result is one hash pair per picture or per sampled keyframe; an empty result means
"too plain to describe", not a failure). Neither starts until the thumbnails are done.

Cleanup is the only place a user's file moves, and the split is deliberate:

```
Swift                                   Rust (cleanup.rs)
planCleanup(group, ticked ids) ───────► review: every file re-checked on disk; kept copy verified; token
  (person reads the review)
approveCleanup(token, ids) ───────────► ids ⊆ review? token live and unused? every file unchanged? → approved paths
  move ONLY those paths to the Trash
cleanupDone(token, ids that moved) ───► records leave the library; ratings/tags/collections merge into the kept copy
```

`cleanupDone` ignores ids that were not approved, so a confused caller cannot remove a record it was not allowed to touch. Rust never
moves or deletes a file; the Swift `Trasher` accepts only `ApprovedTrashDto` values and uses the system Trash call, so Put Back works.

**Errors:** the generated `BridgeError` text is a debug dump. Rust passes the plain sentence for `Refused`, `Invalid` and `NotFound`;
Swift shows `error.userMessage`, never `localizedDescription`.

## Threading and memory ownership

- Rust owns every `Connection`. One writer thread, four read-only WAL connections. Swift never touches SQLite.
- Tokio (via UniFFI's runtime) is used only to await bridge calls; the work itself runs on `spawn_blocking` threads.
  CPU-heavy scanning uses a bounded Rayon pool (2–6 threads).
- Event delivery is one Rust thread that coalesces bursts (120 ms) and sleeps while idle. Swift's `EventHub` fans the single
  callback out to any number of `AsyncStream`s.
- `ResultSet` is an object: the ordered id list stays in Rust (8 bytes per file); Swift asks for pages by position.
- Swift 6 strict concurrency: the generated module compiles in Swift 6 mode; its records are `Sendable`.

## Versioning

The bridge is internal to the app (one binary), so there is no wire-compatibility promise. The *database* schema is versioned and
migrates forward only (`sa-store::migrate`); a library written by a newer app is refused with `SchemaTooNew`.

## Platform notes (found while building this)

- `swift test` / Swift Testing cannot run with Command Line Tools only (SwiftPM's build engine cannot load the Testing macro plugin;
  XCTest is not installed). Tests run as an executable target: `tools/test.sh` / `SATests`.
- With Command Line Tools only, the default macOS 27 SDK makes SwiftUI's `@State` a macro whose plugin ships only with Xcode.
  `build.sh` and `tools/test.sh` build against the macOS 26 SDK in that case. With full Xcode this is unnecessary.
- `AVAssetReader` raises an Objective-C exception (uncatchable from Swift) for sample rates below 8 kHz; the waveform decoder uses 8 kHz.
