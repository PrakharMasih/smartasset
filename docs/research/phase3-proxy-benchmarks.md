# Phase 3 proxy benchmarks: composition, ground truth, method and limits (decision D2)

**What this is.** Runtime and setting comparisons on **public proxy sets**. They separate candidates that are clearly different (a transcription model
that cannot do Hindi, a storage format that loses ranking) and they catch harness mistakes. **They do not select a runtime.** Creator-media results
(`creator-media-evaluation.md`, decision D3) are reported in their own tables and are never averaged with these. No pass bar is applied to a proxy
result as if it were final, and nothing here is reported as a single aggregate without its per-group breakdown.

Machine for every number: MacBook Air, Apple M5, 16 GB, macOS 26, thermal state "nominal" at the end of each run (decision D4: 16 GB is acceptable
for comparing candidates; 8 GB and 24–32 GB runs are still required before any hardware or performance claim). Everything ran inside the Phase 3
sandbox (no network, no access to personal files; decision D1). Versions, commits and checksums: `PINS.md` in the Phase 3 workspace, summarised in
`docs/LICENSES.md`.

## 1. Datasets (what is in them, and what they cannot tell us)

| Set | Composition | Ground truth | Used for | What it cannot tell us |
| --- | --- | --- | --- | --- |
| **COCO captions, 500 sample** | 500 images drawn from the 5,000-image COCO 2014 test split with a fixed seed (20261107); 2,500 human captions (5 per image) | each caption's own image is the one relevant item | text→image, 768/512/256/128 dimensions, f32/f16/int8, vision token budget 70 vs 140 | Photographs of everyday scenes, captions written to describe one image. No screen recordings, no video, no stylised or vertical footage, English only. Captions are far more descriptive than the vague searches creators type |
| **COCO captions, 5k (D5)** | the whole 5,000-image test split; 25,000 captions | as above; for caption→caption: the other four captions of the same image | vector index recall and latency on real vectors | same limits; also **the 500 sample is a subset of it**, so the two are not independent |
| **ESC-50 subset** | 200 five-second environmental clips, 4 per class × 50 classes, five major categories (animals, natural soundscapes, human non-speech, interior/domestic, exterior/urban) | the 4 clips of a class are relevant to the query that is the class name | text→sound | Clean, short, single-source clips with one label. No music, no layered ambiences, no long recordings. The queries are the class names, nothing like the free text a creator types. Only 50 queries: a single query moves hit@10 by 0.02 |
| **Generated speech** (macOS `say`) | 40 utterances (169 s): 8 each of US/UK English, Indian-accented English, Hindi (Devanagari), Hinglish (Devanagari with English words in Latin script), English with ESC-50 noise at 10 dB SNR; plus one 59.5 s clip of eight sentences with known start times | exact reference text; sentence start times known by construction | transcription error, timestamp error, text↔speech retrieval | **Synthetic**: cleaner than any recording, one voice per utterance, no overlapping speakers, no disfluencies. The same eight sentences recur in the English groups, so those groups are not independent. Hinglish references fix one script convention |
| **FLEURS Hindi, 40 utterances** (a record for the later language phase) | 40 utterances sampled with a fixed seed from the 418-utterance Hindi test split of Google's FLEURS: read sentences, 22 female and 18 male speakers, 464 s | the dataset's transcripts (raw, with punctuation) | transcription of real Hindi | Read Wikipedia-style sentences in quiet conditions. Not code-mixed, not conversational. No claim is made for Hindi: English is the first priority |
| **Long English recording, 8.3 minutes** | the 40 LibriSpeech utterances above joined with silences of 1.0–2.5 s (fixed seed); each sentence's true start is its placement plus the silence at the head of the utterance, found by a level threshold (good to about 0.05 s) | exact transcripts; 40 known starts | long-form transcription, dropped sentences, timestamp accuracy | One voice-per-sentence audiobook read, studio quiet, no overlap, no music; the joins are artificial |
| **LibriSpeech test-clean, 40 utterances** | 2 utterances (14–55 words) from each of the first 20 speakers; real read English | official transcripts | transcription on real human speech | Read audiobook speech, studio-clean, US/UK English only. No Hindi, no noise, no conversation |

Licences: COCO annotations CC BY 4.0 (images carry their Flickr licences); ESC-50 CC BY-NC 4.0 (clips have their own); LibriSpeech CC BY 4.0. All were
fetched as plain data, checked against published hashes where the publisher gives them, kept in the Phase 3 workspace outside the repository, and used
for measurement only.

## 2. Query difficulty (what is and is not stratified)

- **COCO captions:** bucketed by caption length (short ≤ 8 words, medium 9–12, long 13+, counted from the text), because short captions are the vague ones.
  The hardest queries are listed by rank in every result, e.g. "A photo of an outside with various things in the scene" (rank 485 of 500).
  This is a **proxy for difficulty only**: no creator-written vague, mood or style queries exist in these sets.
- **ESC-50:** difficulty is the category (animals are hardest) and the phrasing (bare class name vs "the sound of …").
- **Speech:** group (language, accent, noise) and, for the timeline clip, sentence position.
- **Not stratified yet, and required by D3:** hard negatives chosen to look or sound close, queries that need two concepts or one detail inside a long
  recording, code-mixed queries, queries about on-screen text. These come with the creator-media set.

## 3. Metrics (exactly as computed; `spikes/vector-bench/src/bin/eval.rs`)

- **hit@k:** share of queries for which at least one relevant item is in the top k (k = 1, 5, 10).
- **MRR@10:** mean of 1/rank of the first relevant item when that rank is ≤ 10, otherwise 0.
- **precision@10:** relevant items in the top 10 divided by min(10, number of relevant items for the query). With one relevant item per query
  (COCO text→image) it **equals hit@10**, which is why the two columns match there; with 4 relevant clips per class (ESC-50) it is a real measure.
- **Ranking:** exact cosine scan of the whole corpus, ties broken by position. Queries whose relevant set is empty are not counted.
- **Dimensions** 512/256/128 are the first components of the 768-d vector, re-normalised (Matryoshka). **Storage formats:** f16 as it would sit in SQLite;
  int8 with one scale per vector as it would sit in an index.
- **Transcription:** word error rate and character error rate after lower-casing, removing punctuation and splitting on whitespace (letters, digits and
  combining marks are kept; Devanagari vowel signs are marks, so a plain `\w` would cut Hindi words apart: this bug was found and fixed during this phase).
  RTF = processing time ÷ audio duration. **Timestamp error:** for each of the eight sentences in the timeline clip, the absolute difference between the
  recognised first word's start and the known start, after aligning recognised words to the reference.
- **No confidence intervals yet.** The proxy sets are small (50 queries for ESC-50, 8 utterances per speech group), so differences of a few points are
  noise: for 50 queries a hit@10 of 0.78 has a 95 % interval of about ±0.11. The creator-media protocol requires bootstrap intervals; they are not
  claimed here.

## 4. Method notes that affect how to read the numbers

- Embeddings: EmbeddingGemma 2 (740M), `task: search result | query: …` for queries and `title: none | text: …` for documents; text, images (70 or 140 vision
  tokens) and audio (16 kHz mono files) through the same bundle. Unit-normalised at 768 dimensions.
- Speed figures exclude the first load unless stated; the first load compiles kernels (GPU) or Core ML models and is reported separately because a user
  pays it once, at first launch.
- One run per configuration. No repetition-to-repetition variance was measured; the GPU and CPU backends of the same model give different vectors
  (section 5), which is a reminder that small differences are not stable.

## 5. Two checks on how far the proxy numbers can be trusted

1. **Corpus size.** The same model and settings give COCO text→image hit@10 of 0.986 on a 500-image corpus and 0.845 on the full 5,000 (hit@1 0.792 against 0.530).
   A bar is only meaningful with its corpus size and distractors. Results on the 500-image sample are kept only as the first comparison and are not quoted as retrieval quality.
2. **Backend agreement.** The same model on LiteRT's GPU and CPU backends produces vectors that agree closely for text (cosine 0.998–0.999) and images (0.991–0.995) and less for
   sound clips (mean 0.980, worst 0.949). On ESC-50 the two backends return the same top-1 sound for 46 % of the class-name queries, and their hit@10 differ by 0.04 (bare class
   names) and 0.10 (a "the sound of …" template) in opposite directions. With 50 queries, differences of that size are noise, and they would also be noise between repeated runs on one
   backend; repeat-run variance was not measured.

## 6. Where the raw results are

`docs/research/phase3-results/` (small text files; the embedding dumps themselves stay in the Phase 3 workspace):

| File | Content |
| --- | --- |
| `eval-500-{gpu,cpu}-*.txt` | the evaluator's tables for the 500-image sample, ESC-50 (two phrasings) and the generated speech sets, per backend |
| `eval-coco5k-gpu.txt` | text→image over 5,000 images and 25,000 captions, and caption→caption over 20,000 documents, with per-length groups, rank distribution and the hardest queries |
| `litert-{gpu,cpu}-perf.json`, `litert-scale-perf.json` | speed, memory and thermal state of each embedding run |
| `litert-gpu-vs-cpu-vectors.txt` | agreement between the two backends' vectors |
| `index-recall-real-vectors.txt`, `index-memory-measured.txt` | exact scan against HNSW on real vectors; computed against measured memory |
| `asr-comparison.txt`, `asr-whispercpp-scored.txt`, `asr-whisperkit-scored.txt` | transcription error, speed and timestamps for every engine and model |
| `asr-long-english.txt`, `asr-real-hindi-and-long.txt` | the 8.3-minute English recording (every whisper.cpp configuration tried, WhisperKit Large and Small) and the real-Hindi FLEURS runs |
| `system-memory-summary.txt`, `system-memory/` | system-wide memory, CPU time and thermal state of each Whisper candidate, three runs each plus idle controls |
| `eval-coco5k-mlx.txt`, `eval-500-mlx-gpu-*.txt`, `mlx-gpu-perf.json`, `mlx-scale-perf.json` | the MLX runtime's retrieval tables and speed, memory and thermal records |
| `litert-vs-mlx-vectors.txt` | agreement between the two runtimes' vectors for the same inputs |
| `provider-litert-gpu.json`, `provider-mlx-gpu.json`, `ui-under-embedding-load.txt` | the in-process and child-process measurements; the grid benchmark with a model embedding on the GPU |

Reproduce: `spikes/data-prep` (datasets), `spikes/embed-bench` (embedding harnesses, run inside `phase3/isolation`), `spikes/vector-bench` (`eval`, `real`), `spikes/asr` (transcription).
