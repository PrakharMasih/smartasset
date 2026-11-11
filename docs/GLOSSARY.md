# Glossary

One name per idea, used in menus, buttons, titles, tooltips, errors and code comments (bama:ux-design step 1).

| Term | Means | Not |
| --- | --- | --- |
| **Library** | Everything SmartAsset knows about: the files in the folders you added | catalog, database, collection |
| **Folder** | A folder on your Mac or a drive that you added. SmartAsset reads it in place | source, watch folder, location, root |
| **Add Folder** | Choose a folder to index. Nothing is copied or moved | import, scan, connect |
| **Remove Folder** | Stop indexing a folder. Its files are not touched | delete folder, disconnect |
| **Exclude** | Skip a subfolder inside an added folder | ignore, hide |
| **Asset** (code only) | One image, video or audio file in the library. In words shown to people: **file**, or **photo**, **video**, **sound** when the kind matters | item, media, entry |
| **Kind** | Image, Video or Audio | type, format |
| **Drive** | A disk, card or network share a folder lives on. Named when it must be plugged in | volume (code only), disk |
| **Offline** | The file's drive is not connected. Files stay in the library | missing, unavailable |
| **Missing** | The file is no longer where SmartAsset saw it, and its drive is connected | deleted, lost |
| **Indexing** | The background work that reads each file's details and makes its thumbnail | processing, analyzing, scanning (scanning is only the step that lists files) |
| **Thumbnail** | The small picture of a file in the grid | preview (preview is Quick Look), icon |
| **Rating** | 0–5 stars | score, grade |
| **Flag** | Pick, Reject or none | mark, star (star is rating) |
| **Color Label** | One of seven Finder-style colors | color tag, color flag |
| **Tag** | A word you attach to files | keyword, label (label is color) |
| **Notes** | Free text attached to one file | comment, description |
| **Collection** | A list you fill by hand | album, folder, playlist |
| **Smart Collection** | A saved search that updates itself | smart folder, smart album, saved search (in the UI) |
| **Search** | The page that opens with the app and the heart of it: one field (⌘F, ⌘K), a "Describe what you’re looking for" invitation before anything is typed, and the matches in the same grid the library uses once words are typed. It looks at names, folders, tags and notes, at the words shown in pictures and videos (**Text in pictures**), and, when the **Model** is ready, at what they show (**search by meaning**) | Smart Search, quick search, command palette, spotlight, AI search |
| **Scope** | The "in …" choice on the Search page that limits a search to one folder, collection or tag (**Everywhere** is the default) | filter (a filter is a condition on the files), location |
| **Best Matches** | The Search page’s results when search by meaning is on, best first. With words only the heading is **Matches** | top results, relevance |
| **Recent Searches** | The last ten searches you acted on (Return or opening a result), kept on this Mac only. **Clear Recent Searches** forgets them | history |
| **Preview** | The small tag beside "Search by meaning is on": it has not been tested on creator media yet (PLAN §16, 2026-11-07) | beta, experimental |
| **Filter** | A condition that narrows the results (kind, rating, date…) | refine |
| **Inspector** | The side panel with details of the selection | info panel, details |
| **Quick Look** | Spacebar preview | preview |
| **Viewer** | The window that shows one file large, with zoom or playback | lightbox, player window |
| **Show in Finder** | Reveal the file in Finder | reveal, locate |
| **Relink** | Point a missing file's record at its new location | repair, fix |
| **Pause Indexing** / **Resume Indexing** | Stop and restart the background work | suspend, stop |
| **Cancel Indexing** | Drop all waiting work. Finished work stays | abort |
| **Search by meaning** | Finding pictures and videos by what they show, from words that need not appear in any name, tag or note. Needs the **Model**; until it is ready, searches are by words only | semantic search, AI search, visual search (in the UI) |
| **Text in pictures** | The words macOS reads in a picture or a video’s frames (a slide’s title, a screenshot, a label), found by searching for them like a name or a tag. Read on this Mac, English first | OCR, text recognition, scanned text (in the UI) |
| **More Like This** | Finding the files whose pictures look most like the one you chose. Starts from a file, not from words. Not the same as **Similar copies** on the Duplicates page, which are near-identical versions of one picture to clean up | find similar, related, visual search (in the UI) |
| **Why This Matched** | The Inspector section on the Search page that says where your words were found in a file, and whether and how closely it looks like what you described | explanation, relevance, score |
| **Moment** | The place in a video that matched a search, shown as a time ("Closest at 0:42"); the Viewer opens there | timestamp, scene, clip (in the UI) |
| **Shows** | The words a picture shows, in the Inspector ("beach", "dog"), worked out from what the picture looks like; each searches your library for that word | tags (those are yours), labels, keywords (in the UI) |
| **Content** | In the Inspector, what kind of picture a file is when a fact says so: "Screen capture" or "Mostly text" | type, kind (Kind is Images, Videos, Audio) |
| **Model** | A downloaded AI file used for search by meaning | engine, network |
| **Download Model** | The one way SmartAsset uses the internet: fetching a model you chose, from Hugging Face, after you see what it is and how big; checked before it is installed | Install, Get, Update (in the UI) |
| **Cleanup** | The sidebar section for housekeeping pages. Today it holds **Duplicates** | tools, maintenance |
| **Duplicates** | The page that lists files you have more than once: groups on the left, the chosen group’s copies side by side on the right | clean-up, dedupe |
| **Exact Copies** | Files with identical content, whatever they are called or wherever they are | clones, identical files (in a heading), true duplicates |
| **Similar** | Pictures or videos that look like the same shot: resized, re-saved or lightly edited | near duplicates, fuzzy matches |
| **Copy** | One file in a duplicate group | duplicate (as a noun for one file), item |
| **Keep** / **Move to Trash** | The two choices on each copy. Every copy starts as **Keep**; choosing **Move to Trash** only marks it for the review | tick, check, delete |
| **Review** | The one button at the bottom of the Duplicates page that opens the list of every marked copy. Nothing moves until you confirm there | cleanup button, apply |
| **Kind scope** | The All · Images · Videos · Audio bar over every page of files. It sets the same kind filter as the Filter menu | tabs, type filter |
| **Suggested to Keep** | The copy SmartAsset would keep: it has your ratings or tags, otherwise it is the sharpest, then the oldest | original, master, best |
| **Match** | How alike a file is to the group's first file, as a percentage. Exact copies are 100% | confidence, score |
| **Space You Could Free** | The size of every copy in a group except the largest | wasted, reclaimable |

## Fixed phrasings

- "Move to Trash" is used for anything that can come back from the Trash. **Delete** is never used for files: SmartAsset never deletes files.
- "Remove" always means "from SmartAsset only", and the confirmation says "Your files are not touched."
- Counts: "1 file", "3 files"; "1 folder", "2 folders".
- On the Duplicates page nothing is chosen for you: every copy starts as **Keep**; you choose **Move to Trash** on the copies to move (or press **Select Extra Copies**), press **Review**, and only then confirm.
- "Your files are not touched" is true of every page except one: **Move to Trash** in a duplicate review.
