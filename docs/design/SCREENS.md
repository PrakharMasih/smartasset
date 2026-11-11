# Screens (UX pass for the MVP screens, plan §12.4)

Archetype: **sidebar window** (library) with a content column and an inspector, plus Settings, a Viewer window and a
system Quick Look panel. Quick-search panel and menu bar item are 1.0 (M1/M2 features of §4.8), not in this milestone.

## Main window

```
┌───────────────┬──────────────────────────────────────────────┬──────────────┐
│ Search        │  [Grid|List]  Sort ▾  Filter ▾  🔍  ·  ⓘ       │  Inspector   │
│ Library       │ [ All · Images 48 · Videos 6 · Audio 3 ]  kind scope           │
│  All Files    │ ┌──── filter chips: ★★★+ ✕  Save…  Clear ─────┐│  (selection) │
│  Missing (n)  │ │                                              ││              │
│ Cleanup       │ │         thumbnail grid / list                ││              │
│  Duplicates   │ └──────────────────────────────────────────────┘│              │
│ Folders    +  │  status bar: "Indexing 3,120 of 12,408 · about 2 min"  ── size ─│
│ Collections + │                                                               │
│ Smart Coll.   │                                                               │
│ Tags          │                                                               │
└───────────────┴──────────────────────────────────────────────┴──────────────┘
```

- **Flow:** the app opens on **Search**. ⇧⌘O / drag folders onto the window / sidebar + → folder picker → files appear while indexing continues.
- **Surface:** sidebar page per place; the kind of file is a scope bar over the grid; other filters are chips in a bar (lightest surface); details in the inspector; no modal for browsing.
- **Entry points for search:** ⌘F anywhere (searches inside the current folder, collection or tag when pressed on one), ⌘K (everywhere), the Search row, the magnifier button on a library page. There is no search field on library pages: the Search page is the one place to search.
- **Toolbar** (over the content column): view, Sort, Filter, the magnifier ("Search in Iceland Trip (⌘F)"), and over the inspector its toggle. The thumbnail-size slider sits at the right of the status bar.
- **Inspector** is hidden on the Search page until there are matches, and on Duplicates.

### States (bama:ux-design step 4)

| State | What shows |
| --- | --- |
| Empty library (first launch) | Welcome: "Add the folders you want to search." + **Add Folder…**; one line "SmartAsset reads your files in place and never changes them." |
| First indexing | Grid appears at once with placeholder tiles; status bar "Indexing 3,120 of 12,408 · about 2 min" with Pause |
| Indexing paused | Status bar "Indexing paused · Resume"; reason when automatic ("on battery", "Mac is warm", "low memory") |
| Drive offline | Tiles keep thumbnails with a drive badge; inspector says "Plug in **Samsung T7** to open this file"; sidebar folder dimmed with the drive icon |
| File missing | Tile with a question-mark badge; inspector "This file is no longer where SmartAsset saw it." ▸ **Show Missing Files** |
| No results | "No files match." + the active filters as removable chips + **Clear Filters** |
| Folder cannot be read | Sidebar folder shows a warning; inspector-free message in the folder's page: "SmartAsset can't read this folder. Allow access in System Settings ▸ Privacy & Security, or remove and add it again." |
| Model not downloaded | Settings ▸ Models only (no feature uses a model in this milestone) |
| Permission not granted | Never asked up front: access comes from the folder picker (no Full Disk Access) |
| Error | Inline banner under the toolbar with the fix; never a modal for background problems |

### Sidebar

Search (first, alone). Library: All Files, Missing (only when there are missing files). Cleanup: Duplicates (when the library has more than one file).
Folders (header **+**): name, small count, status glyph; context menu: Show in Finder, Rescan, Exclude Subfolders…,
Turn Off / Turn On, Remove Folder…. Collections (header **+**), Smart Collections, Tags. Images, Videos and Audio are the **kind scope** bar over the files, not rows.

### Grid (V1–V3)

- Virtual: only visible tiles exist. 250k files scroll smoothly.
- Tile: a square picture, cropped to fill (View ▸ Crop Thumbnails to Squares; off shows each picture whole), on a deeper backdrop, with columns that fill the row so gaps are even. Names are off unless View ▸ Show File Names is on (the tooltip has the name and details). The tile under the pointer lifts 2 pt. Badges sit on the picture, not the cell: duration bottom left; flag, color label and status
  (offline, missing, damaged) together in one capsule top right; the rating bottom right while the pointer is over the tile or the tile is
  selected (View ▸ Show Ratings on Thumbnails keeps it on). Selection is an accent ring around the picture and an accent capsule behind the name.
  Hover on a video scrubs it (V2).
- Keys: arrows move, Space Quick Look, Return opens the Viewer, ⌘A all, 0–5 rating, P pick, X reject, U clear flag.
- Drag out: tiles drag as the original files (Finder, Final Cut, Premiere, Resolve, browsers…).

### List (V6)

Columns: Name, Kind, Date, Duration, Size, Dimensions, Rating. Click headers to sort (Name, Date, Duration, Size, Rating, Kind).

### Inspector (V5)

One file, in this order: large thumbnail; name; kind · size · duration; **Organize** (Rating, Flag, Color Label); **Tags**; **Notes** (one line with "Add a note" until written); **Collections** it is in; the kind’s details (dimensions, codec, fps, duration, camera, lens, GPS); **Camera Settings**; **File** (folder, drive, modified, added, **Show in Finder**, and the path on one line cut in the middle, all of it in the tooltip). "Why This Matched" joins it with S11.
Several files: count and size + shared actions (Rating, Flag, Color Label, Add Tags, Add to Collection). No selection: a short "No Selection" note.

## Search page (S1, S12, S13)

The start page. A **sidebar page** (a place people come back to), not a palette.

```
Before typing                                   After typing
                                                ┌ 🔍 golden hour drone shot ──────────── ⊗ ┐
   ┌ 🔍 Describe what you’re looking for ┐      [All|Images|Videos|Audio]  🌐 in Everywhere ▾   Best Matches · 16 files
        🌐 in Everywhere ▾  [All|Images|…]      ┌──────────────── the library grid ───────────┐
     ✦ Search by meaning is on · 12,408 files  Preview   │  (select, Space, Return, drag out, inspector)│
   Recent Searches                      Clear   └──────────────────────────────────────────────┘
   🕘 street at night                 ✕
   Try: people talking to camera · close-up of hands …
```

- **Look:** before typing, the page has a large heading ("What are you looking for?") with one line saying what the field understands, a glass field over a soft accent wash, the scope and kind choices, the status line, **Newest Files** (six real pictures that open in the Viewer, following the kind and scope) and Recent Searches / Try. Search by meaning is described only as far as it goes: "photos and videos" (S5 sound search is not built).
- **Flow:** ⌘F, ⌘K, the Search row or the magnifier → field focused (the one window that focuses its field on purpose) → type, matches follow after 150 ms and the field moves to the top → ↓ moves into the grid (first file selected) → Return opens the Viewer (and remembers the search) → Escape clears the words, a second Escape leaves the field. Leaving the page drops the words.
- **Scope:** "in Everywhere ▾" lists every folder, collection and tag. ⌘F on a folder page starts scoped to that folder. "No Files Match “…”" offers **Search Everywhere** when scoped.
- **Sort:** Best Match first in the Sort menu (the page’s own order); the other pages keep theirs.
- **Search by meaning status** (one line under the field): *on* ("Search by meaning is on · 57 files" + **Preview**), *preparing* ("Preparing search by meaning · 37 files left. Names, tags and notes work now." + Pause), *loading*, *words only* (the reason, or "Searching by name, folder, tag and note. Search by meaning needs the Model." + **Set Up…**). The field prompt says "Describe what you’re looking for" when meaning is on, "Search by name, folder, tag or note" otherwise. **Try** examples show only when meaning is on.
- **Not built yet (slots reserved):** moments with timestamps (S2), "Why this matched" (S11), drop a file to find similar (S7).

| State | What shows |
| --- | --- |
| Library empty | The Welcome page |
| Nothing typed | The invitation above, with Recent Searches and Try |
| Searching | The previous results stay until the next answer (no flicker) |
| No results | "No Files Match “…”", the scope, **Search Everywhere** and **Clear Filters** |
| Model not ready | See the status line; words always work |

Access: the field is labelled "Search"; ↓ Return Escape ⌘F ⌘K; Recent Searches and examples are buttons; the clear button has a tooltip.

## Viewer window (V4)

Opening a tile from the grid (Return, double-click) grows the Viewer out of it: the tile’s picture flies to where the Viewer shows it (0.32 s), then the Viewer fades in. With Reduce Motion, and when opened from the menu, the Inspector, the list or Newest Files, it just appears.

The subtitle names where the file sits: "7 of 57", or "7 of 16 Best Matches" when opened from the Search page. The toolbar holds Previous/Next, the image zoom controls, Flag (Pick, Reject) and Rating.

Image: fit/100%, pinch and ⌘+/⌘−, drag to pan. Video: system controls plus **frame step** (, and .) and speed. Audio: waveform
with playhead, click to seek, play/pause on Space. ← → step through the results; Esc closes. Chrome fades out when idle.

## Settings

General (Indexing: pause, only on power; Accent), Folders (list with size, count, status, Exclude, Remove), Models (H5),
About. Tabs sized to content.

## Add Folder flow (L1)

⇧⌘O → system folder picker (the only access grant) → if the folder is already added: select it ("Already in your library");
if inside an added folder: "This folder is already included in **Shoots**." (or, if excluded, "…but excluded. Turn off the
exclusion in Folders."); if it contains added folders: they are merged, ratings and tags kept.

## Remove Folder flow

Confirmation (the one place a dialog is right: it discards ratings, tags and notes for these files):
"Remove “Shoots” from SmartAsset?" / "12,408 files will leave your library, with their ratings, tags and notes. Your files are
not touched." / **Remove** · Cancel. Not undoable, so it says so.

## Duplicates (A1, A2, A3)

A sidebar page under **Cleanup**. Entry points: sidebar ▸ **Duplicates**, Library ▸ **Show Duplicates** (⌥⌘D), the badge on the sidebar row (the number of groups).

```
┌ Duplicates ─ [ Exact Copies 3 | Similar 2 ] ─────────────────── 578 KB could be freed ┐
│ ▣ 2 exact copies  1 marked │ 2 exact copies  289 KB each · 289 KB could be freed         │
│   289 KB could be freed    │ ┌────────────┐ ┌────────────┐          Select Extra Copies  │
│ ▣ 2 exact copies           │ │  picture   │ │  picture   │          Clear                │
│ ▣ 3 exact copies           │ └────────────┘ └────────────┘                               │
│                            │ name      🔍   name      🔍   ← same rows on every copy     │
│                            │ ✓ Suggested   (space kept)                                  │
│                            │ Exact copy     Exact copy                                    │
│                            │ [Keep|Trash]   [Keep|Trash]                                  │
├────────────────────────────┴─────────────────────────────────────────────────────────────┤
│ Select Extra Copies in All Groups        1 copy marked for the Trash   [ Review 1 Copy… ] │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Flow:** sidebar ▸ Duplicates → pick **Exact Copies** or **Similar** → choose a group on the left → choose **Move to Trash** on the copies to move (or **Select Extra Copies**) → **Review** → review sheet → **Move to Trash** → banner "Moved 2 files to the Trash · Undo". Way back: Escape closes the sheet; **Undo** (banner or ⌘Z) puts the files back where they were.
- **Surface:** sidebar page (a place you come back to). The review is a **sheet** (one short task that finishes or cancels, and it must list every file). Done is an inline banner with Undo.
- **Nothing is chosen for you.** Every copy starts as **Keep**. You can never mark every copy in a group: when only one is left as Keep, its choice is switched off. **Select Extra Copies** (per group) and **Select Extra Copies in All Groups** (bottom bar, Library menu) mark every copy except the suggested one; files on a drive that is away are left out.
- **One review for any number of groups.** The bottom-right **Review N Copies…** (also Library ▸ Move Ticked Copies to the Trash…) opens a single review of every marked copy. The core still checks each group on its own, so a changed file stops the rest and the sheet says how many files already moved (Undo puts them back).
- **Review sheet:** title "Move 2 Files to the Trash?"; a table of files that go (name, size, modified, match, folder with the full path in the tooltip), a second short table "These stay"; the line "Ratings, tags and collections on these files move to the file that stays."; buttons **Cancel** (Escape, default) and **Move to Trash** (⌘⌫). Bytes: "24 MB".
- **Match** is a percentage on Similar files only. Exact copies say "Exact copy".
- **Not built yet:** Space to toggle Keep/Move to Trash, ⌘Y Quick Look on a copy, and the total size of the marked copies in the bottom bar.

### States

| State | What shows |
| --- | --- |
| Not compared yet | "Checking 124 files for copies…" with a progress indicator, or "Waiting for indexing to finish" while thumbnails are made |
| Held | "Paused" with the reason (same wording as the status bar) and **Resume Indexing** |
| No exact copies | "No exact copies" and one line: "SmartAsset compares files that have the same size, then reads them in full." |
| No similar files | "No similar pictures or videos" and one line: "Plain pictures, such as a black frame, are never compared." |
| Drive offline | Copy dimmed with "Plug in **Samsung T7**"; its box is disabled, tooltip "Plug in “Samsung T7” to move this file." |
| Refused (file changed, link, drive gone) | Inside the sheet, red text under the table with the fix ("changed after it was scanned. Rescan the folder and review again."); the button becomes **Close** |
| Done | Banner "Moved 2 files to the Trash (24 MB)." with **Undo**; the group updates in place |
| Too much | Paths shorten in the middle, full path in the tooltip; the list is lazy, so thousands of groups scroll smoothly |

Access: groups and copies are reachable by Tab and the arrow keys in the list; VoiceOver reads "IMG_0001.jpg, 200 KB, modified 12 March 2024, in /Users/me/shoot-a, suggested to keep" and "IMG_0001.jpg: keep or move to the Trash". Meaning never rests on color: "Suggested to keep" is a word, offline is a word and a symbol.

## Settings ▸ Privacy (H4)

A tab after Models and before About. One heading, "Everything stays on your Mac.", then short facts: no account or sign-in;
nothing about your files, thumbnails, tags or searches leaves the Mac; no analytics, no crash reports sent; SmartAsset reads
files in place and never changes them, apart from duplicate cleanup, which moves files to the Trash only after you confirm;
no network connections at all today (and how to see that yourself). Below, where the library lives, with its size and
**Show in Finder**.
