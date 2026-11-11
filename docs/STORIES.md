# Stories and status (plan §4, §13)

Status as of 2026-11-07. "Verified" says how it was checked; anything marked *not exercised* compiles and is wired up but has not
been driven by an automated test or looked at on screen yet.

## M1 · Library — built

| ID | Feature | Status | Verified |
| --- | --- | --- | --- |
| L1 | Add folders explicitly (picker, drag onto window, Dock/Finder open); indexed in place | Done (Finder right-click is 1.0, M4) | 14 scanner + 16 engine tests on real files; app run on generated library; first-launch screen snapshot |
| L1a | Folder list with size, count, status; remove; exclude subfolders | Done | Engine tests (remove keeps files untouched, exclude drops index rows, absorb merges parent/child with data kept); Settings ▸ Folders snapshot |
| L1b | Access per folder through the picker, security-scoped bookmarks, no Full Disk Access | Done for an unsandboxed build; bookmarks are stored and re-opened at launch | Self-test: folder moved while the app is open and while it is closed; the bookmark followed it both times, same records, rating and tag kept |
| L2 | Live updates inside added folders (FSEvents) | Done | Engine test: new, moved, deleted file picked up; watcher noise (`.DS_Store`, bundles) ignored |
| L3 | Tags/ratings survive move and rename | Done by size + quick-hash (+name, mtime preference); **confirmed by the full hash whenever the library has one** (files up to 512 MiB) | Scanner tests: rename, move, cross-folder move in both event orders, identical duplicates, twin merge, **a look-alike (same size and samples, different content) never takes over a moved file's record** |
| L4 | Unplugged drives stay searchable; app names the drive | Done | Engine test, then a **real disk image ejected and remounted** in the self-test: searchable, dimmed, named, 0 marked missing, no work leased; data back on remount. iCloud placeholders and an SMB share are manual (see ROADMAP) |
| L5 | Per-folder on/off, pause/resume/cancel, only on power | Done | Engine tests for pause, battery, thermal, cancel, resume, disable; policy unit tests |
| L6 | Formats: JPEG, PNG, HEIC, WebP, GIF, TIFF, RAW · MOV, MP4, M4V · WAV, AIFF, MP3, AAC/M4A, FLAC | Done | Real files for every format: 8 camera RAWs (DNG ×2, CR3, RAF, NEF, ORF, RW2, ARW), JPEG (EXIF, rotation, GPS), PNG+alpha, HEIC, TIFF, GIF, WebP, H.264 (incl. phone-rotated), HEVC, ProRes, M4V, WAV, AIFF, AAC/M4A, FLAC, MP3. RAW from cameras macOS does not support fail as *unsupported*, not corrupt. FFmpeg fallback not built |
| V1 | Grid smooth at 250k files | Done | Bench (below) |
| V2 | Hover-scrub video | Done | Self-test on real tiles: frames differ across the width; cached swap 0.009 ms; strip reloads from disk. Synthesised mouse events |
| V3 | Spacebar Quick Look, arrows step | Done | Self-test: opens on the selection, 50 files to arrow through, multi-selection previews exactly those files |
| V4 | Viewer: image zoom, video with frame stepping, audio waveform | Done | Snapshots of all three; frame stepping is AVPlayerView's built-in control |
| V5 | Inspector | Done | Snapshots (single, multi, damaged-file state) |
| V6 | List view, sortable columns | Done | Snapshots (light, dark) |
| W1 | Drag files out to editors, browsers, Finder | Partly | Self-test: copy-only policy, file URL + id only, originals byte-identical (grid and list). Actual drops into Final Cut Pro, Premiere Pro, DaVinci Resolve and a browser are manual (ROADMAP Phase 1) |
| O1 | Tags, rating, pick/reject, colour label, notes | Done, all undoable | Store + search tests; inspector snapshot |
| O2 | Collections | Done (drag onto sidebar, menus) | Store/search/engine tests; snapshot |
| O3 | Smart collections | Done (save from filters; update live) | Search test: stored definition re-runs and changes with the library |
| H2 | Missing-file repair | Done: relink by content (automatic, or **Find in Folder…**), **Remove from Library…** (only missing files can be removed), follows a moved folder through its bookmark | Self-tests + store test; Missing page snapshots |
| H3 | First-run setup | Partly: pick folders, grid appears at once while indexing continues, one-time "Choose Models" step | The models step lists the catalog only (see H5); the banner is not covered by a test |
| H5 | Model manager | Partly: catalog, memory-tier recommendation (D5), sizes marked "about"/unknown | **No download is implemented**; EmbeddingGemma 2 and Whisper need M0 results first |
| C3 | Orientation and aspect from dimensions | Done | Unit tests; filters in search tests |
| S10 | Filter chips (kind, shape, resolution, duration, date, rating, flag, label, tag) | Done early (planned M2) | Search + Kit tests |
| S12 | Keyword search over names, folders, tags, notes | Done for those fields (not transcripts/OCR yet) | 13 search tests incl. hostile input; 250k bench |
| S13 | **Smart Search box**: one input in the middle of the window, results under it as you type | Replaced on 2026-11-08 by the Search page (U2). Was: done. Keyword search (S12) plus, when the model is ready, search by meaning (S1, first slice, see ROADMAP Phase 4) | In-app self-test "smart search" (⌘K menu item, field focused on open, results equal the library search, ↓ ↑ Return Escape ⌘↩); snapshots `smart-search-{empty,results,none}-{light,dark}` |

UX: S13 Smart Search
- Flow: sidebar ▸ Smart Search, Library ▸ Smart Search… (⌘K) → box opens in the middle with its field focused → type, results follow after 120 ms (up to 8, as many as fit) → ↓ ↑ choose, **Return** opens the file in the Viewer, **⌘Return** (Show in Library) shows every match in the grid → **Escape**, a click outside, or ⌘K again closes. Reopening starts with an empty box.
- Surface: a panel inside the window (table row "Input people repeat while they watch the result"), over a dimmed window, centred left to right and 30 % down so the list has room below. It is its own search: typing never changes the grid behind it.
- States: empty "Search 57 files by name, folder, tag or note." (or "Your library is empty. Add a folder, then search it here."); searching "Searching…" (only before the first answer, later answers replace the list without flicker); none "No Files Match “…”" with a hint; error "Search failed: …" (`userMessage`).
- Words: "Smart Search", field "Search your library", button "Show in Library" with tooltip "Show every match in the library (⌘↩)", row subtitle "Video · 0:04 · 960 × 540 · Iceland Trip" (+ "Offline" or "Missing").
- Access: field label "Smart Search", the panel is a modal group, rows are buttons that read "name, details" with the highlighted one selected, the count is announced when results arrive; keyboard-only works end to end. Material, not Liquid Glass, behind the rows (glass let the thumbnails show through and hurt legibility).

## M4 · Duplicates — built (Phase 2)

| ID | Feature | Status | Verified |
| --- | --- | --- | --- |
| A1 | Exact duplicates, read-only | Done | Engine tests: 100 % recall, 0 false groups, same-size-same-samples impostors kept apart, uniques never read in full; **two real mounted drives** in the in-app self-test; files byte-identical after detection |
| A2 | Near duplicates, read-only | **Partly (A2-lite).** Pictures and videos by perceptual hash; **audio is exact-only; heavy crops need the Phase 4 embedding confirmation** | 200 real photos × 10 changes + 10 re-exported clips, run through the real worker and matcher: 0 false pairs; resize and re-encode 100 %, brightness and contrast 99 %, crop 5 % 99 %, crop 10 % 89 %, **crop 20 % 19 %**; negatives are different scenes (no burst shots) |
| A3 | Cleanup: review → confirm → Trash | Done | Guard tests (unconfirmed, changed, link, offline, last copy, reused or unknown review all refused); **real Trash on a disk image, Undo restores byte-identical**; one combined review across groups |
| H4 | Privacy page | Done | Settings ▸ Privacy; `tools/audit-network.sh`: no networking API or crate, no internet socket in 119 samples of a running session |

Also: **Select Extra Copies** (per group, and in all groups), suggested copy to keep, ratings/tags/collections of a removed copy merge into the kept copy, Undo (banner and ⌘Z). Not built: dismissing a group as "not duplicates".

## Not started (milestone order)

- **M2:** S1, S2, S4, S7, S11, C1, C2 (all † features need real-media retrieval tests first), the `sa-vector` crate.
- **M3:** S3, S5, S6. **M4.5:** hardening suite.
- **M5/1.0:** S8, S9, C4, A4, A5, V7–V9, W2, W3, M1–M4, H1.
- **M0 spikes that need hardware, models or media this project does not have yet** — see PLAN.md §13 "M0 status".

## Performance, measured (plan §8)

Dev machine: Apple Silicon, 16 GB, macOS 26.7, release build. **One memory tier only**; 8 GB and 24 GB+ are untested.

| Metric | Target | Measured |
| --- | --- | --- |
| Library open to usable grid, 250k files | < 1 s | 0.32–0.35 s to ready, first grid ≤ 0.95 s (the bench waits 0.6 s for drawing, so this is an upper bound). Was 0.26 s / ≤ 0.9 s before Phase 2 |
| Keyword search, 250k | < 100 ms | 0.1–14 ms (SQLite FTS5) |
| Filtered / sorted query, 250k | < 150 ms | 3–69 ms |
| Grid scroll | display rate | Timer-lateness proxy for main-thread stalls, 250k files, flicking at 15,000 pt/s, in a **worst-case** library (every tile offline-badged, rated and timed): p99 ≈ 8 ms, max < 10 ms, 0.1–1.4 % of ticks late (a late tick ≈ one 60 Hz frame). At an extreme 50,000 pt/s: p99 ≈ 10 ms, ~6.6 % late. Not a frame counter. (An earlier lighter run measured p99 3.3 ms; a regression from per-redraw badge work was found and mostly fixed in Phase 1) |
| Memory, not indexing | < 500 MB | 134–138 MB physical footprint after scrolling a 250k grid (was 93–121 MB before Phase 2: the extra worker, larger job table and page cache) |
| Idle CPU | ~0 % | 0.01 % over 10 s |
| Browse pass (list, hash, store) | ≥ 500 files/s | 10,700 files/s (30k small files, warm cache); rescan with nothing changed 327,000 files/s |
| Full-content hash (A1) | background | 2.1 GB/s on one reader, warm cache (the disk is the limit in practice); only files sharing size and samples with another file are read |
| Picture hash (A2) | background | 1.8 ms per picture from its thumbnail, one at a time |
| Near-duplicate grouping | background | 2.7 s for 262,500 pictures (multi-index hashing, 8 cores) |
| Duplicates page, 250k assets | < 3 s first | 2.5 s first call (6,000 exact + 6,000 similar groups), 15 µs while nothing changed |
| Crash-free sessions | ≥ 99.9 % | Not measurable yet |

Not measured: hashing on a spinning disk or a network share, AI-pass throughput (no model integrated), voice query latency, hover-scrub frame time, 8 GB behaviour, multi-TB libraries.

## UX blocks

The per-screen UX pass (flow, surface, states, words, access) lives in `docs/design/SCREENS.md`; terms in `docs/GLOSSARY.md`.

## UX redesign · search-first (2026-11-08)

| ID | Story | Status | Verified |
| --- | --- | --- | --- |
| U1 | **Navigation:** the app opens on Search; the sidebar is Search · Library (All Files, Missing) · Cleanup (Duplicates) · Folders · Collections · Smart Collections · Tags; Images/Videos/Audio become a Kind scope bar over every page of files; one search path (⌘F, ⌘K, the magnifier); the thumbnail-size slider moves to the status bar | Done | `kit:` sidebar round-trip and scope tests; snapshots `grid-*`, `folder-*`, `collection-*`; menu items checked by the "keyboard" self-test (22 actions) |
| U2 | **Search page:** one focused field, a status line for search by meaning with a Preview tag, Recent Searches, Try examples, a Scope, Best Match order, results in the shared grid, ↓ Return Escape | Done. S2, S7 and S11 slots are reserved, **not built** | Self-test "search page" (⌘F → focused field, typing keeps focus, results equal the library search, ↓ enters the grid, Return opens the Viewer and remembers the search, Escape clears, ⌘F on a folder scopes, ⌘K everywhere, leaving drops the words), with and without the model; `kit:` recent-search tests; snapshots `search-*`. **Search by meaning is still unvalidated on creator media** |
| U3 | **Tiles:** badges on the picture, one capsule for label, flag and status, rating on hover or selection (View ▸ Show Ratings on Thumbnails), accent ring and name capsule for selection | Done | Snapshots `grid-*`, `grid-multi-*`; `tools/grid-lint.sh`; bench on the 250k library with the model off: p99 7.2 ms at 15,000 pt/s (Phase 2 recorded 5 ms), 134 → 143 MB, idle 0.01 % |
| U4 | **Inspector:** Details above File, one-line Notes with placeholder, path on one line, compact empty state | Done | Snapshots `grid-selected-*`, `search-selected-*` |
| U5 | **Duplicates:** groups list, side-by-side copies with the same rows, Keep / Move to Trash per copy, one Review button, wider review sheet with folder locations | Done. Space to toggle, ⌘Y Quick Look and the marked-size total are **not built** | Self-test "duplicates:" (real Trash, Undo, refusal); snapshots `duplicates-*` |
| U6 | **Around it:** Welcome mentions describing a file, Viewer subtitle names Best Matches and gains a Flag control, Settings ▸ Keyboard lists Search and Search Everywhere | Done | Snapshots `viewer-*`, `settings-*`, first launch (`tools/snap.sh empty`) |
| U7 | **More Like This (S7):** from a file (context menu, Inspector button, Library ▸ More Like This, ⌥⌘F) the Search page lists the files whose pictures look most like it; the file is shown as a "Like …" token in the field and is never in its own results | Done. Videos ask with every scene; sounds are not supported yet; the closeness cut-off is rank only (no cut-off), **not validated on creator media** | Engine tests (itself left out, filters apply, "not described yet" is not "nothing like it"); self-test "more like this and why this matched": on 100 COCO photos, precision@5 0.43 against 0.02 for chance, first answer right 55 %; snapshots `search-like-*` |
| U8 | **Why This Matched (S11):** the Inspector, on the Search page, says where each typed word was found (name, folder name, tag, note, text in the picture, with the words around it) and, only if search by meaning added the file, "Looks like what you described" and for a video its best moment | Done. Words are listed only when every word is placed (the keyword search needs all of them); a file not added by meaning has no meaning line | Engine tests (placement, partial words, not-added, moment); self-test above; snapshot `search-selected-*` |
| U9 | **Moments in videos (S2):** a video is described at its scene changes (3 to 16 scenes, never closer than 2 s), each with its time; a video opened from a search starts at the moment that matched | Done for opening at the moment. **Not done:** a time on the result tile, a timeline of moments, clip-to-clip search | Kit test (scene selection rules), self-test "video moments" (4 solid-colour scenes → 4 vectors at 0.5, 3.5, 6.5, 9.5 s; the Viewer starts at the moment), engine test (times kept, best scene named) |
| U10 | **Copies confirmed by meaning (A2):** a group of similar copies keeps only files whose picture looks like the group's first file (0.90) | Done | Engine test; self-test "copies by meaning" (200 photos, 99.8 % of 400 copies stay) |
| U11 | **Shows and Content (C1, C2):** the Inspector lists up to five words a picture shows (each searches the library) and, when a fact says so, "Screen capture" or "Mostly text" | Done. C2 uses facts, not the model (measured unreliable) | Self-test "labels" (91 % of shown labels confirmed on 500 photos); unit and engine tests |
| U12 | **Moments on tiles and in the Inspector (S2):** "▶ 0:42" on a matched video's tile; a Moments row of scene times that open the Viewer there | Done | Self-test "video moments" |

UX: U7 More Like This
- Flow: select one file → context menu "More Like This", Inspector button, Library ▸ More Like This (⌥⌘F) → the Search page opens with a "Like IMG_0042.jpg ✕" token in the field and the closest files in the grid → ✕, Escape or typing words ends it (typing replaces it with a word search).
- Surface: the Search page (table row "A place people come back to"); the token is state of the field, not a new window or sheet.
- States: described (results, "More Like This · 52 files"); not described yet (“Not Looked At Yet”, "SmartAsset hasn’t finished looking at “…”. Try again in a moment." with Search Again); nothing else looks like it (a filter or scope leaves none, with Search Everywhere and Clear Filters); search by meaning not ready or the file is a sound (menu items disabled; the command explains why).
- Words: "More Like This"; token "Like <name>"; summary "More Like This · N files"; tooltip "Find files that look like this one (⌥⌘F)"; token ✕ "Stop looking for files like this one (⎋)".
- Access: every path has a menu item; Escape ends it; VoiceOver reads the token as "More like <name>" and its button as "Stop looking for files like <name>".

UX: U8 Why This Matched
- Flow: Search page, select one file → Inspector shows "Why This Matched" under the file's details; for a video, "Play from 0:42" opens the Viewer at that moment.
- Surface: Inspector section (table row "Shows details of the selection while people keep working").
- States: no section when nothing explains the file; the answer waits 0.3 s after typing or selecting so arrow keys and typing stay light.
- Words: "“sale” is in the name / in a folder name / a tag / in your note: … / written in the picture: …", "Looks like what you described", "Closest at 0:42", "Play from 0:42".
- Access: plain text rows grouped for VoiceOver; the button is reachable by keyboard.

UX: U9 Moments in videos
- Flow: a search by words or meaning finds a video → select it (Inspector shows the moment) → Return or "Play from 0:42" → the Viewer opens and begins at that moment.
- Surface: existing Viewer; nothing new opens.
- States: a video found by name only, or not added by meaning, starts at 0:00 as before; videos described before this change have no times until they are described again (they are queued automatically).
- Words: "Closest at 0:42", "Play from 0:42".

UX: U2 Search page
- Flow: ⌘F, ⌘K, the Search row or the magnifier button → field focused → type; the field moves up and Best Matches fill the grid → ↓ enters the grid → Return opens the Viewer → Escape clears; a second Escape leaves the field.
- Surface: sidebar page (table row "A place people come back to"), not a palette: search is the core of the app and needs the full grid, the inspector, Quick Look and drag-out.
- States: nothing typed (invitation, Recent Searches, Try); searching (previous results stay); no results ("No Files Match “…”" with Search Everywhere and Clear Filters); model loading, preparing, words only, failed (`error.userMessage`).
- Words: "Describe what you’re looking for", "Search by meaning is on", "Preview", "Recent Searches", "Try", "in Everywhere", "Best Matches", "Set Up…", tooltip "Search in Iceland Trip (⌘F)".
- Access: field labelled "Search"; every control has a tooltip or label; Reduce Motion skips the field’s move.

UX: U5 Duplicates
- Flow: sidebar ▸ Duplicates → tab → group → Keep / Move to Trash per copy (or Select Extra Copies) → Review → sheet → Move to Trash → banner with Undo.
- Surface: sidebar page; the review stays a sheet (one short task that must finish or cancel).
- States: unchanged (see SCREENS.md); the last Keep is disabled with a tooltip.
- Words: "Keep", "Move to Trash", "Review 2 Copies…", "2 copies marked for the Trash", "Select Extra Copies in All Groups".
- Access: groups by arrow keys; each copy labelled "name: keep or move to the Trash".
