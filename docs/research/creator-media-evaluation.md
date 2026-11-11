# Creator-media evaluation protocol (Phase 3, decision D3)

**Why it exists.** Phase 3 selects candidates; real creator-media tests validate them. Public proxy sets (COCO captions, ESC-50 sounds, generated speech)
only compare runtimes and settings. **No runtime, model size, vector dimension or pass bar is final until the sets below exist and the candidate passes
them.** Proxy results and creator-media results are reported in separate tables and never averaged together.

This note is the specification. `spikes/creator-eval/validate_dataset.py` checks a dataset against it. The media itself has to come from the owner.

## 1. Permissions and handling

- Only media the owner made, has licensed for this use, or has the written consent of the people shown or heard. Each item records its basis
  (`own work`, `licensed to the owner for this use`, `written consent of the people shown or heard`); the validator refuses items without one.
- Stored only on the owner's Macs, outside any repository and any cloud-synced folder. The Phase 3 workspace stays sandboxed: experiments run with no
  network and no access to personal files, and the dataset folder is the only creator media the workspace sees.
- No third-party private content, no recordings of people who have not agreed, no credentials, financial or health information on screen. Screen recordings
  are reviewed before they are added.
- The dataset is never used to train or tune a model, only to measure one.

## 2. Composition

| Stratum | What belongs in it | Minimum items |
| --- | --- | --- |
| Technical screen recordings | Code editors, terminals, dashboards, design tools, settings screens, slides; with on-screen text | 40 |
| Tutorials and long-form video | Talking-head and screen-share tutorials, interviews, livestreams; **at least 10 recordings over 10 minutes** | 25 |
| Voiceovers | Clean narration over silence or light room tone | 40 |
| Noisy recordings | Street, café, wind, crowd, bad microphones, overlapping speakers | 40 |
| Music | Beds, loops, full tracks, stems in several genres | 30 |
| Sound effects | Impacts, whooshes, foley, ambiences, animals, machines | 40 |
| Footage (A-roll, B-roll, vertical, drone) | The visual material the plan names | 40 |

Languages (owner decision, 2026-11-07: **English first, other languages later**): **every stratum is built in English now**, and English alone is what a candidate is judged on until a later language phase is opened. Hindi and Hinglish (code-mixed) remain in the protocol as the next languages, at least 30 items each, counted across strata, and the validator treats them as optional until then. No multilingual claim is made before they are measured on creator media. Hinglish is written down as people actually speak it,
in Devanagari, in Roman script, or mixed; the transcript convention for each recording is recorded so a transcript error can be told from a script difference.

## 3. Ground truth

- **Queries are written by creators, not generated from captions.** Each carries the feature it tests (S1, S2, S5, S7, S12, C1, C2, A2), its language and a
  difficulty: *easy* (a clear subject), *medium* (needs two concepts or a setting), *hard* (vague, abstract, mood or style, code-mixed, or one detail in a
  long recording).
- At least **100 queries per feature** and at least **30 % hard**. Ties and near-misses are counted, not hidden.
- **Hard negatives are mandatory**: for every query, at least two items that look or sound close but are wrong (the same location on another day, a similar
  tutorial on another topic, the same instrument playing another piece). The retrieval corpus includes them, so a model cannot pass by being roughly right.
- **Moments (S2):** a relevant moment is `(item, start, end)` in seconds. A result counts as a hit when its timestamp falls within **±3 s** of the interval;
  at least 50 annotated moments, most of them in recordings over 10 minutes.
- **Sound (S5):** each event is labelled with its interval and a free-text description a creator would type ("dog barking in the distance").
- **Near duplicates (A2):** pairs labelled same shot, same take edited, or different take; crops are labelled with the fraction removed.
- Two people label a random 20 % of queries independently; **disagreement above 10 %** sends the query back for rewriting.

## 4. Measures and reporting

Per feature and per stratum, with **hit@10, MRR@10 and precision@10** (the same definitions as the proxy sets: `spikes/vector-bench/src/bin/eval.rs`), plus
timestamp accuracy for moments and precision/recall for labels and near duplicates.

- **95 % bootstrap confidence intervals over queries** on every number. No claim is made for a stratum with fewer than 30 queries.
- Results are broken down by language, difficulty and stratum; the hardest 20 queries are listed with their ranks, not just averaged away.
- Dimensions (768, 512, 256) and storage formats (f32, f16, int8) are evaluated on the same queries; a smaller setting is chosen only if no stratum drops
  below its pass bar.
- **A candidate passes only if every stratum passes its bar**, not the aggregate. A runtime that wins on average and fails Hinglish does not pass.
- **Corpus size is part of every result.** The same model scores text→image hit@10 0.986 against 500 images and 0.845 against 5,000 (`phase3-model-spikes.md` §3), so each number is
  reported with the number of items searched, and a pass bar is stated for a named corpus size. Proposed, to confirm once the first creator-media results exist: build the retrieval
  corpus per modality to at least 5,000 items by adding distractors (creator media that is not relevant to any query) to the annotated items and their hard negatives, and
  repeat on the largest library the owner can supply.
- Speed, memory and thermal behaviour are measured on the same machine in the same session, on at least 16 GB; **8 GB and 24–32 GB runs are required
  before hardware support or performance claims are finalised** (decision D4).

## 5. Pass bars (provisional)

Provisional per modality, to be confirmed or changed once the first creator-media results exist.

| Feature | Measure | Provisional bar |
| --- | --- | --- |
| S1 text→image and text→video | hit@10 over creator-typed queries | ≥ 0.90, MRR@10 ≥ 0.60, per stratum |
| S2 moments in video | file hit@10, and timestamp within ±3 s on correct files | ≥ 0.85 and ≥ 80 % |
| S5 text→sound | hit@10 | ≥ 0.80 |
| S7 by example (image, clip, sound) | hit@10 for same scene or source | ≥ 0.95 |
| S12 keyword + semantic blend | hit@10 against keyword-only on the same queries | no stratum worse; +10 points on description-style queries |
| C1, C2 labels | precision at recall 0.7, per label | ≥ 0.90 |
| A2 near duplicates | precision / recall for resize, re-encode, crop up to 20 % | ≥ 0.99 / ≥ 0.95 |
| Transcription (S3) | word error rate, per language and condition | to be set from the first Hindi and Hinglish results |

## 6. How it is built from here

1. The owner supplies media and a first batch of queries in the layout the validator describes (`spikes/creator-eval/example` shows the format).
2. `validate_dataset.py` reports coverage gaps; gaps are filled before any selection run.
3. The same dump format and evaluator used for the proxy sets score each candidate, so the numbers are comparable in method but kept in separate tables.
4. Selection runs are repeated on the 8 GB and 24–32 GB Macs before the hardware tiers in plan §7.2 are fixed.
