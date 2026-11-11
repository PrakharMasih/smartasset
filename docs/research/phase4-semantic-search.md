# Phase 4 · Search by meaning: what was built and what was measured

Status 2026-11-08. **Development under the owner's waiver of the Phase 3 gate (PLAN §16, 2026-11-07). Nothing here is release-approved, and every retrieval number below is on public photographs, never creator media.** The release gate of ROADMAP Phase 3 is unchanged.

## What exists

| Part | Where | Notes |
| --- | --- | --- |
| Vector storage and exact scan | `core/crates/sa-vector` | L2-normalised f16, per-asset best row (a video has one row per frame), filter callback, mean and spread of all scores. All 65,536 f16 patterns round-trip. No graph index (D5: exact scan first) |
| Schema v3 | `sa-store/src/sql/0003_embeddings.sql` | `model_configs`, `embeddings`; a changed file drops its vectors and jobs (`embeddings::clear_derived`) |
| Contract and engine | `sa-providers/src/embedding.rs`, `sa-engine/src/embedding.rs`, `sa-ffi` | Pull-based like the other workers: `next_embedding_batch` / `submit_embedding_results`. No model announced = no jobs, keyword search unchanged. Bad vectors (zero, NaN, wrong length) fail their file, never the batch |
| Blend | `Engine::search_hybrid` | Keyword results and vector results (restricted to what the filters allow) merged by reciprocal rank fusion (K = 60). Only when ordered by relevance; any other order is the keyword search in that order |
| Calibration | `Calibration { min_match, band }`, announced by the model | The best match must reach `min_match` or the library is taken not to answer; files within `band` of the best are kept. **These numbers belong to one model configuration** |
| Swift | `Sources/Workers/Embedding*.swift`, `Sources/Embedding/` | Pictures from their 512 px thumbnail, videos from three frames (20, 50, 80 %), one item at a time. EmbeddingGemma 2 on MLX Swift (owner's choice), text-q8 + vision-q8 weights, 768 numbers, 70 soft tokens per picture, the model's "search" prompt for queries |
| App | `AppModel+SmartSearch.swift`, `SmartSearchView.swift` | The model loads in the background; browsing and keyword search never wait for it. The grid's search box and Smart Search both use the blend |

Configuration id: `embeddinggemma2-mlx-q8-768-soft70-v1`. Calibration: `min_match` 0.70, `band` 0.08.

## Method

The in-app self-test **"semantic search"** (`tools/selftest.sh`, `SELFTEST_ONLY="semantic search"`) runs the real app, the real model and the real pipeline:

1. COCO val2014 photographs with five human captions each (Phase 3 data, `data/coco`) are copied into a test library next to the 57 generated demo files, indexed (thumbnails, hashes, vectors) and searched.
2. **Caption → photo:** the first caption is the query; the answer is correct when the photo it describes comes back (hit@k = in the first k results of the blended search). The same query is also run as a keyword search for contrast.
3. **Scores:** for all captions (first two when the library is 5,000), the cosine of the best match, its distance to the 50th match, and its z-score against every file's score.
4. **One-word questions:** 29 words (dog, pizza, giraffe …); a photo is relevant when one of its captions contains the word. Precision and recall inside bands below the best match.
5. **Nonsense:** 20 invented sentence-style queries ("kubernetes deployment yaml", "quarterly revenue", "zzzzqq" …) and 15 invented one-word ones ("blorp", "invoice", "the" …): how high does the best match score?
6. **Guards** (after the calibration was chosen): at most 10 % of the nonsense queries answered by meaning, no one-word question with matching photos left unanswered, at least 90 % of captions reaching `min_match`.

`SA_SEMANTIC_PHOTOS=500` uses the 500-photo set; `5000` the 5,000-photo set (about 17 minutes).

## Results (16 GB M5, macOS 26.7, MLX Swift 0.32.3, release build)

### Caption → photo

| Library | Cut-offs | hit@1 | hit@5 | hit@10 | Words alone | Per question |
| --- | --- | --- | --- | --- | --- | --- |
| 158 files (100 photos) | none (first attempt) | 0.94 | 1.00 | 1.00 | 0.00 / 0.00 | 12–16 ms |
| 558 files (500 photos) | none | 0.81 | 0.97 | 0.99 | 0.00 / 0.00 | 14 ms |
| 5,058 files (5,000 photos) | none | 0.52 | 0.76 | 0.85 | 0.00 / 0.00 | 16 ms |
| 558 files | `min_match` 0.70, band 0.08 | 0.79 | 0.94 | 0.96 | 0.00 / 0.00 | 14 ms |
| 5,058 files | `min_match` 0.70, band 0.08 | 0.51 | 0.76 | 0.84 | 0.00 / 0.00 | 17 ms |

Phase 3 measured hit@10 0.845 at 5,000 images with the same model; the app reproduces it (0.85). Corpus size is what moves these numbers, as Phase 3 found (0.986 at 500 images, 0.845 at 5,000), so every figure names its library size. "Words alone" is 0 because a caption is in no file name, tag or note: only meaning can find the photo.

The cut-offs cost about three points of hit@10 at 558 files (0.99 → 0.96): captions whose best match is below 0.70 (3 %) fall back to the keyword search, which finds nothing. That is the price of rejecting nonsense. At 5,058 files they cost one point (0.85 → 0.84): captions score higher there (99 % reach 0.70), because the right photo has more competition from similar ones but its own score does not change.

### Raw scores (no cut-offs)

Best-match cosine, 500-photo library unless stated. The z column is the best match's distance from the average file in standard deviations.

| Queries | n | min | p5 | median | p95 | max |
| --- | --- | --- | --- | --- | --- | --- |
| Captions, best match | 2,500 | 0.653 | 0.712 | 0.765 | 0.810 | 0.846 |
| One word, best match | 29 | 0.723 | 0.723 | 0.744 | 0.776 | 0.782 |
| Sentence nonsense, best match | 20 | 0.595 | 0.601 | 0.657 | 0.682 | 0.682 |
| One-word nonsense, best match | 15 | 0.622 | 0.622 | 0.669 | 0.705 | 0.705 |
| Sentence nonsense at 5,058 files | 20 | 0.603 | 0.623 | 0.674 | 0.713 | 0.713 |
| Captions, z | 2,500 | 2.78 | 4.13 | 5.65 | 7.50 | 10.02 |
| Sentence nonsense, z | 20 | 2.43 | 2.51 | 2.89 | 4.05 | 4.05 |
| Sentence nonsense, z, at 5,058 files | 20 | 3.79 | 3.86 | 4.23 | 6.45 | 6.45 |

**Why the cut-off is an absolute cosine and not a z-score.** The best of N unrelated scores creeps up with N (nonsense median z 2.3 at 158 files, 4.2 at 5,058) and lands on top of real captions' lower end (p5 4.1–4.6), whereas the cosine of a real match does not depend on N. The absolute best match separated the groups at every size measured. Its weakness: it is specific to one model, one prompt style and one picture budget, hence "announced with the configuration".

### One-word questions: how wide a band below the best match

Library of 558 files, 29 words; precision understates (captions are incomplete, a photo may show a dog and not say so). The 5,058-file run (30 words) is below: with ten times the files, the same band keeps ten times as many.

| Band below the best | Files kept (avg) | Precision | Recall |
| --- | --- | --- | --- |
| 0.02 | 4.5 | 0.99 | 0.36 |
| 0.03 | 6.8 | 0.97 | 0.52 |
| 0.05 | 10.5 | 0.92 | 0.78 |
| **0.08 (chosen)** | 17.8 | 0.71 | 0.92 |
| 0.12 | 101.2 | 0.22 | 0.98 |

Ranking puts the best first whatever the band, so the band only decides how long the tail is.

At 5,058 files (30 words, no cut-offs applied to the measurement):

| Band below the best | Files kept (avg) | Precision | Recall |
| --- | --- | --- | --- |
| 0.03 | 38.5 | 0.99 | 0.31 |
| 0.05 | 78.3 | 0.97 | 0.61 |
| **0.08 (chosen)** | 127.6 | 0.86 | 0.87 |
| 0.12 | 365.9 | 0.42 | 0.96 |

The engine looks at the 200 best matches at most, so in a very large library a one-word question returns at most 200 files by meaning (plus its keyword matches).

### The cut-off itself (library of 558 files)

Share of queries whose best match reaches the cut:

| Cut | Captions | One-word | Sentence nonsense | One-word nonsense |
| --- | --- | --- | --- | --- |
| 0.64 | 100 % | 100 % | 65 % | 93 % |
| 0.68 | 99 % | 100 % | 5 % | 33 % |
| **0.70 (chosen)** | 97 % | 100 % | 0 % | 7 % |
| 0.72 | 92 % | 100 % | 0 % | 0 % |
| 0.74 | 78 % | 66 % | 0 % | 0 % |

At **5,058 files** the same table reads: captions 99 % at 0.70 (97 % at 0.72, 88 % at 0.74), one-word questions 100 % at every cut up to 0.74, sentence nonsense 5 % at 0.70 and 0 % at 0.72, **one-word nonsense 27 % at 0.70** and 0 % at 0.72 (best matches up to 0.715). So in a larger library more of the junk gets through: single words like "invoice" or "tax" can reach 0.70 against some photograph. 0.70 was chosen to favour not missing a real question; 0.72 would have rejected all of the nonsense measured at both sizes, at the price of 3 to 8 % of long captions. The guard in the self-test tolerates up to 10 % of nonsense queries answered, and 1 of 20 did at 5,058 files.

### Speed

5,000 photographs were embedded in 712 to 760 s end to end (142 to 152 ms each, two runs), **including** thumbnails, metadata, duplicate hashes and the 57 demo files: this is the whole pipeline, not the model alone, and it is not a measurement of the Phase 4 gate "AI pass ≥ 20 images/s", which is **not met or tested here** (Phase 3 measured 16.5–19.1/s for the model alone). A question (embedding the words and the blended search) takes 12–17 ms from 158 to 5,058 files.

## Accuracy: what was tried to make it find the right file more often (2026-11-08)

The results above are the **70-token** configuration (`…-soft70-v1`). The app now uses **140 picture tokens**
(`embeddinggemma2-mlx-q8-768-soft140-v1`, owner's choice: up to about twice the indexing time). Every lever below was
measured before it was kept; three were rejected.

**Method.** Offline on Phase 3 dumps (`~/Library/Developer/SmartAsset/phase3/results/mlx-scale`, COCO 5k: 5,000 photos,
25,000 captions) with `spikes/vector-bench` (`eval`, and `rescore`, which tunes on the captions of photos 0–2,499 and scores
on those of photos 2,500–4,999, against all 5,000 photos). Picture dumps made in the no-network sandbox with
`spikes/embed-bench/mlx-bench` `mlx-scale --budget N [--thumb 512]`; query wordings with `mlx-queries`. Then the in-app self-test.

| Lever | Result (5,000 photos unless stated) | Kept? |
| --- | --- | --- |
| **140 picture tokens, from the 512 px thumbnail** | hit@1 0.537 → **0.566**, hit@5 0.778 → 0.799, hit@10 0.851 → **0.868**, MRR@10 0.639 → 0.665 (all 25,000 captions). 74 → 116 ms per picture (model only, p50) | **Yes** |
| 280 picture tokens (500 photos only, originals) | hit@1 0.785 → 0.820 (140: 0.808); 269 ms per picture | No: ~4× time, owner chose ≤ 2× |
| Picture from the original (640 px) instead of the 512 px thumbnail, 140 tokens | hit@1 0.567 vs 0.566, hit@10 0.867 vs 0.868; 141 vs 116 ms | No: no gain, more decoding |
| Question worded "a photo of …" (≤ 3 words), or averaged with the plain wording | One-word questions AP@1000 0.923 (as typed) → 0.889 / 0.915; the gap between the weakest real word and the strongest nonsense shrinks from 0.015 to −0.003 / 0.007 | No: as typed is best |
| Pseudo-relevance feedback (move the question toward its top 3 or 10 photos) | hit@1 0.545 → 0.507–0.535 (every 5th test caption) | No: worse |
| Hub correction from a bank of past questions (CSLS: score − 0.5 × mean of the photo's 5 best scores against the bank) | hit@1 0.559 → 0.563 (100 questions), 0.566 (300), 0.577 (1,000), 0.582 (2,000), 0.592 (5,000), 0.605 (12,500) | **Not now** (owner): see below |
| Hub correction with no bank (the photo's neighbours among the library's photos); subtracting the mean question; centring the photos | +0.5 points or worse | No |

**Why hub correction is not built.** Its bank would be the user's own searches, and the worst case was measured: when the
bank already holds other questions about the very photo being looked for (someone searching for the same file again in other
words), the photo is pushed down (hit@1 0.545 → 0.519 at weight 0.5; 0.542 at 0.25). That is exactly the "find it again"
search Recent Searches serves, so the owner chose to wait for a creator-media set before deciding.

**Swap without a gap.** Changing the picture budget gives a new configuration, so the library is described again. While
that runs, the vectors of the previous configuration of the **same model** (same model, weights, modality and size) keep
answering for the files not yet described again. A file's old vector is deleted in the same transaction that stores its new one,
so storage never holds two descriptions of a file; files that cannot be described again (missing, failing) keep the old one
and stay findable (`sa-engine` `VectorCache` fallback, `embeddings::drop_superseded`, engine test
`while_the_library_is_described_again_search_still_finds_every_file`). A different model never shares.

**In the app at 140 tokens** (self-test "semantic search", 16 GB M5):

| Library | hit@1 | hit@5 | hit@10 | Before (70 tokens) |
| --- | --- | --- | --- | --- |
| 558 files (500 photos) | 0.80 | 0.94 | 0.96 | 0.79 / 0.94 / 0.96 |
| 5,058 files (5,000 photos) | **0.54** | **0.78** | **0.85** | 0.51 / 0.76 / 0.84 |

At 5,058 files the 0.70 cut answered 99 % of captions and every one-word question, and let through 1 of 20 sentence-nonsense
and 1 of 15 one-word-nonsense questions (at 70 tokens: 27 % of one-word nonsense). Band 0.08 kept 134 files on average
(precision 0.85, recall 0.89). End to end, 5,000 photos took 985 s (197 ms each including thumbnails and hashes; 142–152 ms at
70 tokens). The 45 ms per question of that run was measured while Rust was compiling on the same Mac; idle, the 158-file
library answers in 12 ms. The 5,058-file latency was **not re-measured idle**.

Calibration kept at `min_match` 0.70, band 0.08, re-measured at 558 files: at 0.70, 96 % of captions, every one-word question
and **none** of the 35 nonsense questions reach the cut (at 70 tokens, 7 % of one-word nonsense did). Band 0.08: precision
0.65, recall 0.93 (0.05: 0.90 / 0.81). Best match of a real one-word question 0.71–0.77; of nonsense 0.59–0.70.

**Text in pictures (S4)** was added in the same pass, because for screenshots, slides and title cards the words shown are a
stronger signal than anything COCO measures: Vision (`VNRecognizeTextRequest`, accurate, English) reads each picture from
the original at up to 2,048 px and each video at three frames; the words join the keyword search (`asset_text_fts`), so the
blend with search by meaning needs nothing new. Measured only by the self-test "text in pictures" (generated pictures); not
on creator media.

## Search by example, why it matched, and moments in videos (2026-11-09)

**More Like This (S7).** The question is the file's own stored vectors (a video asks with every scene and a file counts at its
best); the answer is the closest files the filters allow, never the file itself, ranked, with no cut-off (at most 200).
Measured through the real app on 100 COCO photos (`SA_SEMANTIC_PHOTOS` not needed; self-test "more like this and why this
matched"): for photos whose captions share a word (30 words, at least 3 photos each, up to 3 query photos per word, 42 asked),
the share of the first k answers (k = 5 or the number of other photos of the kind) described by the same word was **0.43
against 0.02 for chance (22×)**, and the first answer was one of the kind for **55 %**. Captions are incomplete (a photo may
show a dog and not say so), so both numbers understate. Public photos, not creator media.

**Why This Matched (S11).** Placing words is exact because it asks the search's own keyword index, one word and one column at
a time. It lists words only when every word is placed (the keyword search needs all of them), because listing the few words of a
caption that happen to be in a folder name explained nothing. The meaning line follows the search's own rule (the question's
best match reaches the model's minimum and the file is within the band of it): a first version that only checked the score
showed "Looks a little like what you described" for a plain file-name search, which was wrong. For 10 photos asked by their
own caption, 9 were added by meaning (the tenth has a best match under 0.70 and is found by words only).

**Moments (S2).** Scenes: a video is sampled at up to 96 evenly spaced instants as 16 × 12 grey pictures; a new scene starts
when the picture changes by at least 10 % (mean grey-level difference) and at least 2 s after the last scene; 3 to 16 scenes
(an even spread when there are more, fixed places along it when there are fewer). The limits are **first guesses**. Checked
only on a generated clip of four solid-colour scenes (4 vectors at 0.5, 3.5, 6.5 and 9.5 s, correct). **Real recordings
(talking head, B-roll, screen recordings) are not measured**, so neither the limits nor the timestamp accuracy are
validated. A scan with a tolerance of ±0.5 s was needed: with "any keyframe" a video with few keyframes showed the same
picture at every instant and hid the cuts. Cost: up to 16 embeddings per video instead of 3 (about 116 ms each at 140 tokens).

## Copies, labels and moments (2026-11-09)

**A2, copies confirmed by meaning.** 200 real photos (Phase 2 labeled set) and 10 altered copies of 40 of them, all described
from a 512 px picture (self-test "copies by meaning"). Cosine to the original: resize 50 % ≥ 0.983, resize 25 % ≥ 0.971,
re-encode q40 ≥ 0.984, q10 ≥ 0.976, brighter ≥ 0.934, less contrast ≥ 0.940, crops 5/10/20 % ≥ 0.967 / 0.954 / 0.937,
**grayscale ≥ 0.851**; the closest *different* photo: median 0.837, p95 0.907, max 0.931. Cut-off 0.90: 99.8 % of copies stay
(a grayscale copy or two may leave a group); 7.5 % of the closest different photos would pass, but confirmation only runs inside
groups the fingerprints formed, which had no false pair on this set. 20 % crops (missed by fingerprints) all score ≥ 0.937:
meaning could find them; not built.

**C1, labels.** 30 single words on 500 COCO photos, ground truth "a caption uses the word": cut-off 0.66 precision 0.73 /
recall 0.90; **0.68: 0.90 / 0.81**; 0.70: 0.96 / 0.62; giving only a picture's 3 best labels changes nothing above 0.66.
Through the engine with the app's own list of 33 words, 157 labels were shown on the 12 words a caption can confirm, 91 %
confirmed. Captions are incomplete, so precision understates. Multi-word labels were not measured, so the list has none.

**C2, kinds of picture by the model: rejected.** Closest of four kind phrases, on 60 COCO photos and 12 generated
screenshots, text pages and illustrations each. Best wording ("a photo taken with a camera" …): photos 51/60, screenshots 12/12,
text pages 12/12, illustrations 5/12 (7 called screenshots); "a photograph"/"an illustration" called 20 of 60 photos
illustrations. Generated samples are easy cases, so real accuracy would be lower. The app uses facts instead.

**More Like This, with full ground truth.** An earlier figure counted answers among photos without captions as wrong; with every
COCO photo's captions: 100 photos, precision@k 0.43 against 0.03; **500 photos, 0.57 against 0.02, first answer right 70 %**.

## Crashes at quit: found and fixed (2026-11-09)

**What it was.** Of 40 SmartAsset crash reports from 8–9 Nov, **39 of the 40 MLX crashes had the main thread inside
`exit()`**, about 8 s after launch, the moment the self-test finished. The process was exiting while the embedding worker (or a
question being embedded, or the model still loading) was mid-evaluation on the GPU, and the C++ runtime tore MLX's global
objects down under it (`~CommandEncoder` on the main thread; `set_input_array`, `get_command_encoder` or Metal's "completed
handler after commit" on the worker). The self-test quit with a bare `exit()`; the app's own Quit stopped the workers but did
not wait for a model that was loading or a question being embedded, and quitting during launch skipped shutdown entirely.

**What was wrong in the earlier diagnosis.** MLX's per-thread streams were suspected; a new self-test, "model under load"
(320 embeddings from 8 tasks of 4 priorities at once), passed 5 times out of 5 on the unchanged code, so concurrent use of a
loaded model does not crash. The pattern only appeared when crash reports were tabulated by time since launch and by what the
main thread was doing.

**Fix.** `EmbeddingModel.close()`: the model counts its running calls, refuses new ones once closing, and returns when the last
finishes. `AppModel.shutdown()` waits for the model to finish loading and then closes it, after the workers stop and before the
engine closes. Quit during launch now goes through shutdown too, and the self-test exits through the same shutdown.

**Evidence.** Before: 10 crashes in 12 launches of the "search page" self-test (this morning), about a third in earlier batches.
After: **0 crashes in 30 launches**, then a full self-test run (19 of 19 pass) and the 500-photo measurement (unchanged:
hit@1 0.80, hit@5 0.94, hit@10 0.96), with **no new crash report**.

**Still open: rare main-thread crash.** Four reports over four days (8 Nov 10:07 and 18:25, 18:32; 9 Nov 10:29), not at exit:
the Swift runtime's main-executor check (`swift_task_isMainExecutorImpl`) reads a bad pointer, from `MainActor.assumeIsolated`
in a power or window callback and once from a compiler-inserted check in `AssetCollectionView.acceptsFirstResponder`. Two
coincided with the Mac going to sleep or waking. Not reproduced in any run after the fix; cause unknown; nothing was changed for
it. If it recurs, the report and the system log around it are the next step.

**Self-test environment.** Keyboard checks can only run while SmartAsset is in front. When another app is in use, macOS may keep
it in the background; those checks now report UNVERIFIED ("run again when the Mac is idle") instead of FAIL, and
`tools/selftest.sh` holds the Mac awake (`caffeinate -i`) during a run.

## Limits: read before quoting any number

- **Public photographs, not creator media.** COCO is everyday scenes with sentence captions; creator libraries (screen recordings, B-roll, drone footage, sound) are different. No pass bar for any † feature is claimed or agreed.
- **Rare one-word questions can fall below the minimum.** In the 158-file library, words that only 1 to 4 photos' captions use were answered by meaning 20 times out of 22; "snow" (3 photos) and "baseball" (1 photo) were not, because the best photo scored under 0.70 for the bare word. A question about something the library holds only once or twice may therefore get the keyword answer only. In the 558- and 5,058-file libraries every word with five or more photos was answered; rare words were not tabulated there.
- The nonsense and one-word lists were written by one person for this test; they are not a sample of what people type. The one-word ground truth is caption-word containment.
- One Mac (16 GB M5), one library size per row, at most 5,058 files, no filter combinations, no 8 GB or 24–32 GB machine. No support is claimed for untested configurations.
- **Video is not measured.** Three frames per video are embedded and the blend scores a video by its best frame; the only video files in the tests are generated clips.
- **Audio is not searched by meaning.** Sounds are keyword-only.
- The blend applies when results are ordered by relevance (typed words with no other order chosen). With another order the answer is the keyword search in that order.
- The calibration (0.70 and 0.08) was chosen on the same data it was then guarded on. A second, independent set is needed before it is trusted.
- Third-party code: MLX Swift and the EmbeddingGemma2 package are linked into development builds from the pinned Phase 3 clones, with the network- and process-capable code reviewed in `phase3-model-spikes.md` §2.1 still present. The trimmed build and a no-network helper are release items, not done.
- The shader library is the one SwiftPM builds (Metal compiler of Xcode 27.2, Metal Toolchain 27B47), shipped as `mlx-swift_Cmlx.bundle`; it has not been checked on macOS 14 to 25.
