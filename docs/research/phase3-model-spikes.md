# Phase 3: model and retrieval spikes (M0 remaining)

Started 2026-11-07 on a MacBook Air, Apple M5, 16 GB, macOS 26.7, Xcode 27.2 (full Xcode is installed; `xcode-select` still points at the
Command Line Tools, so builds that need the Metal compiler use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
Rule of this phase: a number is either measured here, quoted from a named source, or marked **pending**. Nothing is estimated; an extrapolation is
labelled as one.

**Phase 3 selects candidates. Real creator-media tests validate them. Production adoption requires reproducible results, dependency and licence
review, and hardware testing** (owner's rule, 2026-11-07). Nothing below selects a runtime. Proxy results are reported in
`phase3-proxy-benchmarks.md` (datasets, ground truth, metric definitions, limits) and are kept apart from creator-media results, which do not exist yet
(`creator-media-evaluation.md`). Raw outputs for every table are in `phase3-results/`.

## Where it stands

**Language scope (owner, 2026-11-07): English is the first priority; other languages come later.** Everything below is judged on English first. Hindi and Hinglish results are kept as records and make no claim.

| Item | State |
| --- | --- |
| EmbeddingGemma 2: availability, modalities, licence, sizes | **Done**, from primary sources (section 1) |
| Metal Toolchain (approved) | **Installed**, build 27B47, verified (`PINS.md`) |
| Runtime comparison, LiteRT-LM against MLX Swift (text, image, audio; retrieval; GPU/CPU; throughput; memory and thermals; cold start; provenance) | **Complete on proxy data, no selection** (section 2). Neither is adopted; creator English media, 8 GB hardware and the binary reviews decide |
| 512 vs 768 vs 256 dimensions | **Measured on proxy sets, both runtimes** (section 3): 512 costs 0.2–0.3 points hit@10 at 5,000 images, 256 about 1.2, 128 about 8. Not final until creator media |
| Vector index: exact scan vs HNSW, on real vectors (D5) | **Measured** (section 4). Exact scan meets the latency requirement at every size tested; HNSW not introduced |
| Vector memory calculations checked against measured memory (D5) | **Done** at 250,000 vectors, 768 and 512 dimensions (section 4.3) |
| Whisper: WhisperKit (provisional preferred) and whisper.cpp (alternative) | **Measured on English** short and 8-minute speech, with system-wide memory (section 5). Energy **not measured** (needs root; script ready). Hindi/Hinglish kept as records |
| Inference architecture: in-process behind a provider interface | **Prototype and measurements** (`phase3-inference-architecture.md`). Plan §6.9 stays open |
| Creator-media evaluation set (D3) | **Protocol, validator, intake and review tools written; media not supplied** |
| 8 GB and 24–32 GB runs (D4) | **Not available.** Recorded in plan §16. No support is claimed |
| Release gate | Defined (ROADMAP). **No runtime is production-approved** |
| Licences | Register updated (`LICENSES.md`). Open: the LiteRT binary; MLX's networking-capable dependencies |

## Owner decisions of 2026-11-07, and where each stands

| Decision | What was done | What is still open |
| --- | --- | --- |
| **D1** third-party experiments, isolated | LiteRT-LM, MLX Swift, whisper.cpp and WhisperKit built and run only in `phase3/isolation` (`sandbox-exec`: no network, personal files denied). Dependencies and build scripts read; versions, commits and checksums in `PINS.md`; no blanket Bash permission rule. One attempt to switch off Xcode's package sandbox was refused by the safety check and not worked around: MLX's Metal library is built with Apple's compiler instead (`spikes/embed-bench/tools/build_mlx_metallib.py`) | SwiftPM runs with `--disable-sandbox` inside the outer profile (nesting is impossible) |
| **D2** provisional bars; hit@10, MRR@10, precision@10; document method | `creator-media-evaluation.md` §5; `phase3-proxy-benchmarks.md` | Bars confirmed only after creator-media results |
| **D3** creator-media evaluation | Protocol; validator that now also requires a person's verdict on every annotated moment and a second reviewer on 20 %; `ingest.py` and `review.py`; **English required now, other languages later** | **Authorized media and queries from the owner**; manual validation of ground truth and timestamps |
| **D4** 16 GB accepted | All numbers carry the machine; absence of 8 GB and 24–32 GB Macs recorded in plan §16 | Those machines; no support claimed until tested |
| **D5** exact scan first; real recall; verified memory | Section 4 | Real vectors at 250,000 |
| **Metal Toolchain** | Installed and recorded | |
| **Embedding runtime** | Section 2: every listed criterion measured for both | **No selection**; creator English media, 8 GB, binary reviews |
| **Whisper** | WhisperKit large-v3 Turbo 626 MB prototyped as primary; whisper.cpp kept; system-wide memory, thermals, timestamps, English and Hindi accuracy, first-launch measured | **Energy** (owner runs `sudo spikes/asr/energy_session.sh`); thermals over a long session; creator English speech |
| **Inference architecture** | Provider interface, child-process stand-in, five measurements | Real XPC, memory pressure, sandboxed helper; decision stays open |
| **Release gate** | Recorded | All five conditions open |

## 1. EmbeddingGemma 2 (confirmed)

Primary sources: the Hugging Face repository `google/embeddinggemma-2` (API record and model card), Google's developer blog, the LiteRT-LM
documentation, and the community MLX port's model card.

| Fact | Value | Source |
| --- | --- | --- |
| Released | 6 October 2026 by Google DeepMind; ungated, public | Hugging Face record (`gated: false`, 498,510 downloads at 7 Nov) |
| Licence | **Apache 2.0** (card, repository metadata). The card also says "Deployments must adhere to the **Gemma Prohibited Use Policy**" | Model card |
| Size | 740M total: 270M text backbone (130M transformer + 140M embedder), 170M vision encoder, 300M audio encoder. Encoders load separately: text 270M, text+image 440M, text+audio 570M, full 740M | Model card |
| Modalities | Text (100+ languages, code), images, video, audio, and interleaved mixes, in one 768-dimensional space | Model card |
| Dimensions | 768 native; Matryoshka truncation to **512, 256, 128** (re-normalise after truncating; query and corpus must share a dimension) | Model card |
| Google's own quality by dimension (MMEB v2 overall / MSEB retrieval MRR@10) | 768d 59.01 / 69.54, **512d 58.38 / 69.18**, 256d 56.24 / 66.76, 128d 45.65 / 56.71. "128d degrades multimodal quality substantially" | Model card |
| Context | 8,192 tokens shared by all modalities. Text 1 token per subword; **image 280 tokens (about 29 images; down to 70 tokens)**; **video 140 tokens per frame at 1 fps (about 58 frames, about 1 minute)**; **audio 25 tokens per second (about 327 s)** | Model card |
| **Numerical precision** | **Run in bfloat16 or float32. Never float16: the model returns NaN or silently degraded embeddings.** Storing the finished, normalised vectors in f16 is a different matter (measured safe below) | Model card |
| Prefixes | Text only: `task: search result \| query: …` for queries, `title: none \| text: …` for documents; images, video and audio take no prefix | Model card |
| Google's reported speed, MacBook Pro M5, LiteRT-LM | text 9.5 ms (GPU) / 31.3 ms (CPU); text+image 37.3 ms (GPU, 70 vision tokens) / 151 ms (CPU); text+10 s audio 195 ms (GPU); memory 233–478 MB (GPU) | LiteRT-LM bundle card |

**What this changes in the plan**

1. The plan's description of the model (§7.1) is accurate. Two additions: the **float16 ban** (inference in bf16/f32 only), and the card's **Prohibited
   Use Policy** sentence, which belongs in the licence register and the Models tab.
2. The plan says video is split into scenes (≤ about 58 frames per embedding). Confirmed by the 140-tokens-per-frame cost.
3. **Neither Swift runtime embeds video today.** The community MLX runtime states "No video, interleaved multimodal documents"; Google's LiteRT-LM Swift
   `EmbeddingEngine` examples show text, image and audio only and document no video input. Video search (S2, S7 clip→clip) would therefore be built
   from **per-keyframe image embeddings plus the soundtrack's audio embedding**. That is a design change to verify with the retrieval tests, not a given.
4. Google's table says 512 dimensions loses about 0.6 on the multimodal average and about 0.4 on audio retrieval against 768, in exchange for 1.5×
   smaller vectors and a 1.65× faster scan (measured below). It needs confirming on our own sets (pending).

## 2. The two runtime candidates, compared on every criterion the owner listed (no selection)

Both run the same EmbeddingGemma 2 model family on the same inputs, GPU backend, 16 GB MacBook Air M5, thermal state recorded. **Proxy data only. This section selects nothing.**

| | LiteRT-LM Swift (Google) | MLX Swift, community runtime (`EmbeddingGemma2Swift`) |
| --- | --- | --- |
| What it is | `google-ai-edge/LiteRT-LM` v0.19.1, Apache-2.0; Swift API marked **Early Preview**; engine is a **closed prebuilt binary**; one 485 MB `.litertlm` bundle (int4/int8 quantisation-aware trained) | Third-party package (MIT), created 6 Oct 2026, one maintainer, 4 stars; builds on `ml-explore/mlx-swift` 0.32.3; weights converted by another third party (q8 text 288 MB + q8 vision 193 MB + bf16 audio 611 MB) |
| **Text** (one query / per text in a batch of 32) | 18.3 ms / 17.2 ms (batching gives nothing) | 10.3 ms / **2.9 ms** |
| 25,000 captions as queries + 20,000 as documents | 430 s + 339 s | **81 s + 61 s** |
| **Image**, 70 vision tokens / 140 / 280 (p50) | 101 ms / 216 ms / not offered | **62 ms / 114 ms / 269 ms** |
| **Audio**, 5 s clip (p50) | 110 ms | **77 ms** |
| Image throughput, one at a time; best with requests in flight | 10.0/s; **10.1/s** (serial engine) | 16.5/s; **19.1/s** (preparation overlaps GPU work) |
| Sustained: image p50 over the 500-image run, then over the 5,000-image run | 100.9 → 102.4 ms (steady) | 61.9 → **73.6 ms** (+19 %; thermal state "fair" at the end) |
| **Cold start** (process start to ready, three towers) | 0.58 s with the GPU kernel cache warm; **3.1 s the first time ever** | 1.3 s every time (no cache) |
| **Memory** (process footprint): loaded / peak | **439 MB / 650–722 MB** | 1,211 MB / 1,554–2,576 MB (all three towers; text only 409 MB) |
| **Thermal** (state at the end of a run) | "nominal" after the 500-image run, "fair" after the 21-minute 5,000-image run | "fair" after both its 500-image run and its 9-minute 5,000-image run |
| **CPU backend** | Works: text 31.7 ms, image 187 ms, audio 217 ms | **Unusable**: 8 captions had not finished after 11.5 minutes (GPU: 8.5 ms each) |
| **GPU/CPU consistency** | Same text 0.998–0.999 cosine, images 0.991–0.995, **sounds 0.980 (worst 0.949)**; top-1 sound agrees for only 46 % of ESC-50 queries | Not measurable (no usable CPU path) |
| Phase 4 gate (≥ 20 images/s on 16 GB) | Not met: 10/s | Not met: 19.1/s best case on short bursts, 13.6/s sustained |

**Cross-modal retrieval quality, proxy sets, 768 d.** Corpus size matters more than the runtime (section 3).

| | LiteRT-LM | MLX | n |
| --- | --- | --- | --- |
| COCO text→image, 5,000 images: hit@1 / hit@10 / MRR@10 | 0.530 / 0.845 / 0.633 | 0.537 / **0.851** / 0.639 | 25,000 queries |
| COCO caption→caption, 20,000 documents: hit@10 | 0.754 | 0.758 | 5,000 |
| 500-image sample: hit@10 (70 / 140 tokens) | 0.986 / 0.990 | 0.986 / 0.990 | 2,500 |
| ESC-50 text→sound: hit@1 / hit@10 | 0.22 / 0.78 | 0.24 / 0.78 | 50 |
| Generated speech: text→speech hit@1; speech→text hit@1 | 0.958; 1.000 | 0.917; 0.975 | 24; 40 |

On the 5,000-image set MLX is ahead by about 0.6 points, the size of each estimate's sampling interval (about ±0.4): a tie in practice. **The audio weakness is not LiteRT's quantised audio tower:** the bf16 audio tower in the MLX runtime scores the same 0.78 hit@10 on ESC-50, so the cause is the model or the proxy set.
**The two runtimes' vectors are not interchangeable:** the same inputs agree at cosine 0.992 for text, 0.976–0.983 for images and only **0.938 for sounds (worst 0.904)**, and top-1 sound agrees for 34 % of queries. An index built by one runtime cannot be queried by the other.

**Concurrent image throughput and isolation** (the provider prototype, `phase3-inference-architecture.md`): LiteRT's engine is a serial actor and gains nothing from concurrency, batches of 8 or a child process; MLX's encoder is also a serial actor, and only overlapping image *preparation* with GPU work raises it from 16.5 to 19.1 images/s. Neither design change lowered per-call speed, hurt main-thread timing, or (child process) cost more than 2 ms per call.

**Security and dependency provenance**

| | LiteRT-LM | MLX Swift |
| --- | --- | --- |
| Where the code comes from | Google; Swift wrapper is source, the engine is a 143 MB **prebuilt binary**. The xcframework zip's SHA-256 equals the checksum in the package manifest. The binary is **ad-hoc signed** (no publisher identity) and cannot be rebuilt here | Built here from source at pinned revisions: runtime commit 2c7815fc… (980 lines read), mlx-swift 19601207…, submodules mlx v0.32.2 (1f8e74e3…) and mlx-c v0.6.0+9 (ebc88f10…), ten pinned dependency clones. Metal shaders compiled here with Apple's signed toolchain (183 MB library) |
| Network and process functions the built binary imports | **sockets** (`socket`, `connect`, `bind`, `listen`, `accept`, `getaddrinfo`, `send`, `recv`), **process creation** (`fork`, `execvp`, `posix_spawn`), `dlopen` | **sockets** (same set), **`NSURLSession`** (from the Hugging Face client pulled in by `swift-transformers`), `popen`/`system` (MLX's CPU JIT compiler), `dlopen` |
| Why those imports are there | Not knowable from outside; the binary is closed | Known from the source: the Hugging Face model-download client, MLX's *distributed ring* backend (compiled in; only starts if distributed mode is requested) and the CPU JIT. None is used by our calls, all are linkable code |
| Weights | Google's bundle, Apache-2.0 (+ Prohibited Use Policy sentence); size recorded, no publisher checksum | Converted by a third party on Hugging Face; all 14 files match the SHA-256 Hugging Face publishes, but the **conversion itself is unverified** |
| Behaviour seen under a no-network sandbox | Ran correctly | Ran correctly |

Neither runtime is network-free by inspection, and a no-network sandbox proves only that neither *needs* the network. **The Privacy page's claim needs an enforced control, not an inspection:** a runtime audit of each binary outside the sandbox (`tools/audit-network.sh`) and, for the out-of-process design, an App-Sandboxed helper with no network entitlement. MLX's extra networking code could be removed (vendor only the tokenizer; build without distributed mode); that is not done and is a cost of choosing it.

**Reading the comparison without selecting.** MLX is 1.6–2× faster per image and 6× faster for batched text, a tie on 5,000-image retrieval, buildable from source and reviewable, but uses 2.7× the memory (decisive for an 8 GB Mac, untested), runs hotter, has no working CPU fallback, comes from a one-maintainer package with third-party converted weights, and needs a custom Metal library build (SwiftPM cannot). LiteRT is lighter, steadier and has a CPU fallback and a first-party source, but is slower, serial, and ships as a closed ad-hoc-signed binary of unknown network behaviour with a preview-stage API. What would decide it, none of which exists yet: creator **English** media, an 8 GB result, the binary reviews, and a plan for the 20 images/s gate.

### 2.1 MLX Swift chosen (owner, 2026-11-07): where each risky import comes from

Traced in the built `provider-bench` (mlx-swift 0.32.3, swift-transformers 1.3.0, swift-huggingface 0.13.0) by reading the undefined symbols of every object file (`nm -u`), then the sources. Read-only; nothing rebuilt.

| Import | Object file | Source | Used by our calls? | Remedy |
| --- | --- | --- | --- | --- |
| `socket`, `connect`, `bind`, `listen`, `accept`, `getaddrinfo`, `send`, `recv` | Cmlx `utils.o` | `mlx/distributed/utils.cpp` (TCP helpers for the **ring** backend, which `mlx-swift/Package.swift` enables on purpose: "enable ring, disable MPI + NCCL + JACCL") | No: only runs if distributed mode is requested | Build with `distributed/ring/no_ring.cpp` instead of the ring backend and exclude `distributed/utils.cpp` |
| `popen`, `system` | Cmlx `jit_compiler_conditional.o` | `backend/cpu/jit_compiler.cpp`: compiles CPU kernels by calling the system C++ compiler at run time | No on the GPU path; it is the "CPU path" measured as unusable | Build without the CPU JIT (CPU `compile` falls back to un-fused ops) |
| `dlopen` | Cmlx `compiled_conditional.o` | `backend/cpu/compiled.cpp`: loads the library the JIT just built | No | Goes with the JIT |
| `NSURLSession` (14 symbols) | `Hub.o`, `HuggingFace.o`, `EventSource.o` | swift-transformers **`Tokenizers` depends on `Hub`**, which depends on `swift-huggingface` (model download client, server-sent events) | No: the encoder only calls `AutoTokenizer.from(modelFolder:)`, a local folder | Link a tokenizer without `Hub` (a Tokenizers fork with the `Hub` dependency cut, or a small local Gemma tokenizer) |
| `fork`, `execvp`, `posix_spawn` | none in the MLX build | (they were in the LiteRT binary) | n/a | n/a |

**Two layers, both needed before release:** (1) a trimmed build so the shipped binary contains none of the code above (checked by the same `nm -u` listing, which becomes a test); (2) an OS-enforced control, because a trimmed build can regress silently: inference in a helper with no network entitlement and an app-level audit (`tools/audit-network.sh`). Plan §6.9 (in-process vs XPC) decides where (2) lives. **Both change third-party code or its build, so they wait for the owner's permission** (CLAUDE.md).

## 3. Retrieval on the proxy sets (summary; datasets, method and limits in `phase3-proxy-benchmarks.md`)

**Corpus size changes the answer more than any setting.** The same model, the same vision budget (70 tokens), the same kind of query:

| COCO text→image, 768 d | Images in the corpus | Queries | hit@1 | hit@10 | MRR@10 |
| --- | --- | --- | --- | --- | --- |
| first comparison | 500 | 2,500 | 0.792 | 0.986 | 0.865 |
| **D5 run** | **5,000** | **25,000** | **0.530** | **0.845** | **0.633** |

A 10× larger corpus costs 26 points of hit@1 and 14 points of hit@10. Any pass bar (the draft says hit@10 ≥ 0.90) is meaningless unless the corpus it was measured on is
stated, and a 250,000-file library will be harder again. Part of the 5,000-image failure is not the model's fault: some COCO captions cannot be answered
("I am unable to see the image above", "There is no image for me to write about"; ranks 4,580–4,736 of 5,000). **3.3 % of the 25,000 queries find their image
nowhere in the first 50.** Creator-media sets must therefore be run with a stated corpus size and distractors (the protocol requires hard negatives).

| Dimensions (COCO 5k, text→image, f32) | hit@1 | hit@10 | MRR@10 |
| --- | --- | --- | --- |
| 768 | 0.530 | 0.845 | 0.633 |
| 512 | 0.529 | 0.842 | 0.631 |
| 256 | 0.508 | 0.833 | 0.612 |
| 128 | 0.421 | 0.763 | 0.527 |

Caption→caption (20,000 documents): 768 d 0.754 hit@10, 512 d 0.754, 256 d 0.752, 128 d 0.736. **512 dimensions is within 0.3 points of 768 on both
tasks; 128 is clearly worse; 256 sits between.** Storage format: f16 and int8 change hit@10 by at most 0.001. Short captions are harder than long ones
(hit@10 0.807 against 0.914). All on English photographs and captions only.

| Other proxy sets (768 d, f32) | hit@1 | hit@10 | MRR@10 | n |
| --- | --- | --- | --- | --- |
| ESC-50 text→sound, class name, GPU | 0.220 | 0.780 | 0.365 | 50 queries |
| same, CPU | 0.320 | 0.740 | 0.426 | 50 queries |
| ESC-50 "the sound of …", GPU / CPU | 0.160 / 0.260 | 0.720 / 0.820 | 0.314 / 0.403 | 50 queries |
| Generated speech: text→speech (English, Hindi, Hinglish) | 0.958 | 1.000 | 0.972 | 24 queries, 40 clips |
| Generated speech: speech→text | 1.000 | 1.000 | 1.000 | 40 queries, 24 sentences |

With 50 queries, a hit@10 of 0.78 has a 95 % interval of about ±0.11. **The GPU and CPU runs of the same model disagree by about that much on the
"the sound of …" template (0.72 against 0.82), and in the opposite direction to the bare class names (0.78 against 0.74)**, so the earlier impression that the template makes things
worse was noise. The draft bar for text→sound (hit@10 ≥ 0.80) is neither met nor failed by a 50-query proxy; it cannot be assessed until the creator set
exists. The speech sets are 24 easy synthetic sentences and say almost nothing.

## 4. Vector index

### 4.1 Decision D5: exact scan first, on real vectors

Real EmbeddingGemma 2 vectors (LiteRT GPU, 768 d, unit-normalised): the 5,000 COCO images, and 20,000 captions as documents. Queries: 5,000 real captions
(`spikes/vector-bench/src/bin/real.rs`; `phase3-results/index-recall-real-vectors.txt`). Truth is the exact f32 scan. "vs int8" isolates the graph's own
error from quantisation. Exact int8 uses all 10 cores; the f32 and f16 scans are single-threaded.

| Corpus, 768 d | Exact f32 (1 thread) | Exact int8 (10 cores) | HNSW ef=64: p50, agreement with exact int8 / f32 | hit@10: exact f32 / exact int8 / HNSW ef=64 |
| --- | --- | --- | --- | --- |
| 5,000 images | 433 µs | 72 µs | 22 µs, **0.998** / 0.974 | 0.834 / 0.833 / 0.833 |
| 20,000 documents | 1.79 ms | 173 µs | 24 µs, **0.997** / 0.979 | 0.754 / 0.755 / 0.754 |

- **On real vectors HNSW recall is not the problem the near-random worst case suggested:** with ef=64 it returns 99.7–99.8 % of the exact int8 top-10 (ef=128: 99.9 %),
  and the task-level hit@10 differs from the exact scan by 0.001 or less. Recall drops at ef=16 (98 %) and costs nothing in time that matters.
- **The int8 format itself loses 2–3 % of the exact f32 top-10 membership** (agreement 0.974–0.981) but not task success (hit@10 within 0.001). 512 dimensions behaves the same
  (agreement 0.973–0.979; table in the results file).
- **The latency requirement is 150 ms for semantic search (plan §8).** The query embedding on GPU takes about 18 ms, leaving over 130 ms. The exact int8 scan takes
  72 µs at 5,000 vectors and 173 µs at 20,000 (measured); the earlier synthetic measurement gave 1.0 ms at 250,000 × 512 d and 1.65× that at 768 d (data-independent;
  the scan reads every byte once). **Extrapolating the measured per-vector cost (about 8.7 ns per 768-d vector on 10 cores) gives about 2 ms at 250,000 and about 9 ms
  at 1,000,000.** Even the single-threaded f32 scan, the slowest form tested, extrapolates to about 22 ms at 250,000. Both are an order of magnitude inside the budget.
- **Under D5, HNSW is therefore not introduced**: the exact scan does not fail the latency requirement at the plan's scale. HNSW's recall requirement is met
  by ef ≥ 64 on the data tested, so it remains a documented option for a library beyond a few million vectors or for a feature that needs many queries per second.
  What was **not** tested: real vectors at 250,000 (none exist here), mixed-modality corpora, filtered search on real vectors, and a database-resident layout.

### 4.2 Why the "worst case" in section 4.4 does not contradict this

The near-random synthetic vectors in section 4.4 (recall 0.22–0.33 at 100,000) have no neighbour structure; real embeddings do. Both facts stand: HNSW recall is a
property of the data, an exact scan has none, and on the real data tested HNSW is accurate. That is a reason to keep the exact scan as the default and the
reference for testing any index.

### 4.3 Memory: computed against measured (250,000 vectors, process resident size from `ps`)

`phase3-results/index-memory-measured.txt`. Each representation was allocated while the others stayed alive, so none could reuse freed memory.

| 250,000 vectors | 768 d computed | 768 d measured | 512 d computed | 512 d measured |
| --- | --- | --- | --- | --- |
| f32 matrix | 732.4 MB | 748.3 MB | 488.3 MB | 498.3 MB |
| f16 matrix (SQLite blob form) | 366.2 MB | 366.2 MB | 244.1 MB | 244.2 MB |
| int8 + one f32 scale per vector | 184.1 MB | 184.0 MB | 123.0 MB | 123.0 MB |
| HNSW graph, M = 16 | 32.8 MB (137 B/vector) | **41.5 MB (174 B/vector)** | 32.8 MB | **41.5 MB** |

- **Dimensions and element precision were right** (f16 and int8 to within 0.1 MB; f32 within 2 %).
- **The HNSW overhead was understated by 27 %**: 174 bytes per vector measured against the 137 computed. The extra is probably the per-node `Vec` headers of the upper levels and allocator rounding (not isolated). The corrected overhead is still small beside the vectors (about a fifth of the int8 vector at 768 d), so the
  conclusion does not change, but 174 is the number to use.
- **Freed memory is not returned.** After the f32 source was dropped, the process stayed at 1,340 MB (768 d) and 907 MB (512 d), while what it still needed computes to 583 MB and
  400 MB. Resident size counts pages the allocator has kept; they are reusable and the system can reclaim them under pressure, so the true cost is lower than
  the figure, but it is not zero. Design consequence for Phase 4: build and load the index straight from the stored vectors (f16 or int8, memory-mapped or streamed),
  never through a resident f32 copy of the whole library.
- Whole-library figures in section 4.5 remain a model (stated assumptions), now with the corrected per-vector numbers: **at 250,000 vectors, 768 d int8 is 184 MB
  and 512 d is 123 MB resident, plus 42 MB if a graph were built.** Verified at that vector count; the assumed vectors per file are not.

### 4.4 Synthetic vectors (measured earlier; speed and storage do not depend on the values, recall does)

Our own code, safe Rust only (the product forbids `unsafe` outside the bridge), int8 vectors with one scale per vector, 10 cores.
Synthetic clustered unit vectors stand in for embeddings. **Speed and storage do not depend on the vectors; HNSW recall does**, so recall is
reported for a structured set (members of a cluster about 0.6 cosine apart, like real embeddings) and for a near-random worst case.

**Storage per vector** (the HNSW graph column is the computed figure; section 4.3 measured 174 B)

| Dimension | f32 | f16 (SQLite blob) | int8 + scale (scan or index) | HNSW graph (M = 16) |
| --- | --- | --- | --- | --- |
| 768 | 3,072 B | 1,536 B | 772 B | +137 B |
| 512 | 2,048 B | 1,024 B | 516 B | +137 B |

Quality of the storage formats on top-10 agreement with exact f32 (20,000 vectors): **f16 0.9992–1.0000, int8 0.981–0.986.** Worst f16 component error
6.1e-5, so storing normalised vectors as f16 is safe (the float16 ban is about running the model, not storing its output).

**Search time, 512 dimensions, k = 10, structured vectors (p50)**

| Vectors | Exact int8 scan, all cores | HNSW ef = 64 | HNSW recall@10 | HNSW build |
| --- | --- | --- | --- | --- |
| 50,000 | 249 µs | 50 µs | 0.99+ | 14.6 s |
| 100,000 | 379 µs | 73 µs | 1.00 | 25.8 s |
| **250,000** | **986 µs** | **67 µs** | 1.00 | **65.7 s** (single thread) |

768 dimensions: exact scan 370 µs at 50,000, 624 µs at 100,000 (1.5–1.65× slower than 512).

**Worst case (near-random vectors, no neighbour structure):** HNSW recall@10 falls to 0.38–0.46 at 50,000 and **0.22–0.33 at 100,000** (ef 32–128), while the
exact scan is unaffected. HNSW's recall is a property of the data; an exact scan has none.

**Filtered search at 250,000 vectors (exact scan of only the matching vectors vs a graph walk that applies the filter)**

| Matching | Share | Scan p50 | HNSW ef=64 p50 | HNSW recall (ef 64 / 256) |
| --- | --- | --- | --- | --- |
| 255 | 0.1 % | **19 µs** | 304,580 µs | 1.00 / 1.00 |
| 5,107 | 2 % | **217 µs** | 3,939 µs | 0.97 / 0.999 |
| 12,502 | 5 % | **292 µs** | 1,490 µs | 0.945 / 0.998 |
| 49,926 | 20 % | 733 µs | **397 µs** | 0.986 / 0.998 |
| 125,208 | 50 % | 1,041 µs | **179 µs** | 1.00 / 1.00 |

**Findings**

1. **An exact int8 scan is fast enough at the plan's scale.** 250,000 vectors take about 1 ms; 1 million would take about 4 ms. HNSW is 15× faster
   per query but needs a 66-second single-threaded build, 137 more bytes per vector, incremental-update logic, and has data-dependent recall.
   **Recommendation for Phase 4: ship the exact scan first and add HNSW only if a library passes about 1 million vectors or a feature needs many
   queries per second.** This replaces the plan's "HNSW above about 20k vectors" (§6.7); the 20k threshold was never the issue, the graph walk is
   *worse* than a scan for any filter below roughly 20 % of the library.
2. **RAM, not disk, is the binding constraint.** The int8 index must be resident to be fast: 516 B per vector at 512 dimensions is 516 MB per million
   vectors (260 MB at 256). Disk is irrelevant by comparison: f16 plus an int8 copy is about 1.6 KB per vector.
3. **Library totals are a model, not a measurement** (assumptions: one third each images, videos, audio; 1 vector per image, 6 per video, 4 per audio
   file; photo 5 MB, video 200 MB, audio 10 MB). For 250,000 files that is about 0.92 million vectors: **about 1.5 GB on disk (under 0.01 % of media
   size, far inside the 3 % budget; thumbnails dominate) and about 470 MB resident at 512 dimensions.** Long footage multiplies the video vectors,
   so the memory-mapped, paged-in layout (or 256 dimensions) is the Phase 4 design question, not the 3 % budget.

## 5. Whisper: WhisperKit (provisional preferred) against whisper.cpp (alternative), English first

Owner decisions: WhisperKit with quantised Large-v3 Turbo is the primary prototype, whisper.cpp stays as the alternative, and **English is the first priority language**. Before adoption: system-wide memory, energy, thermals, timestamp accuracy, accuracy, first-launch. Models: WhisperKit 1.1.1 with `openai_whisper-large-v3-v20240930_626MB` (Argmax's compressed Large-v3 Turbo) and `openai_whisper-small_216MB`; whisper.cpp v1.9.5 with `ggml-large-v3-turbo-q5_0`, `ggml-large-v3-turbo` (fp16) and `ggml-small`. Raw outputs: `phase3-results/asr-*.txt`, `system-memory-summary.txt`.

**English, real speech.** 40 LibriSpeech utterances (clean read speech) and one **8.3-minute recording made by joining 40 of them with known sentence starts** (true starts good to about 0.05 s).

| | LibriSpeech 40: WER | 8.3 min: WER | sentence starts found | timestamp error median / p90 / max |
| --- | --- | --- | --- | --- |
| **WhisperKit Large-v3 Turbo 626 MB** | 0.021 | **0.024** | **40 / 40** | 0.15 / 0.52 / 2.39 s |
| WhisperKit Small 216 MB | 0.028 | 0.028 | 40 / 40 | 0.32 / 0.52 / 0.57 s |
| whisper.cpp Large-v3 Turbo q5_0, defaults | 0.028 | 0.163 | 37 / 40 | 1.49 / 3.19 / 9.40 s |
| same, no context carry-over (`--max-context 0`) | | 0.085 | 35 / 40 | 1.93 / 3.38 / 4.56 s |
| same, plus DTW word alignment (`--dtw`, flash attention off) | | 0.106 | 34 / 40 | **0.10 / 0.30 / 0.48 s** |
| same, plus Silero VAD | | 0.210 | 30 / 40 | 50 s median: unusable |
| whisper.cpp Large-v3 Turbo fp16, defaults | 0.026 | 0.296 | 33 / 40 | 1.76 / 4.68 / 24.85 s |
| whisper.cpp Small, no context, DTW | 0.028 | 0.281 | 26 / 40 | 0.10 / 0.25 / 3.58 s |

- **On long English, WhisperKit is far more complete and accurate out of the box.** whisper.cpp loses 3–7 of 40 sentences with Large (14 with Small) and loops on some; no setting tried brought its WER below 0.085 (WhisperKit: 0.024) or found all 40 sentences. Its word timing, once DTW is on, is the most accurate measured (median 0.10 s) *for the sentences it finds*. Dropped speech is the worse failure for search. The whisper.cpp alternative got a fair attempt (four configurations); VAD in v1.9.5 with DTW gave wrong times.
- **For English, Small is nearly as good as Large-v3 Turbo in WhisperKit** (WER 0.028 against 0.024, all 40 found), at 216 MB instead of 626 MB, but with coarser timestamps (median 0.32 s against 0.15 s). One clean 8-minute recording supports a **tiered English default as a hypothesis**, not a decision; it must be re-run on creator English (noise, overlapping speakers, technical vocabulary). The earlier "Small is not the default" rested on multilingual use (below) and is reopened for English.
- Short clean English is a tie across every configuration (WER 0.02–0.03): it cannot rank anything.

**System-wide cost** (the long recording, 3 runs each, increase over a quiet baseline; the idle control drifts +50 to +230 MB on its own, so differences under about 300 MB are not resolved):

| | system memory in use, mean (runs) | peak | process footprint | CPU seconds | wall time |
| --- | --- | --- | --- | --- | --- |
| WhisperKit Large-v3 Turbo 626 MB | **+1,000 MB** (984–1,049) | +1.2 GB | 192 MB | 7.5 | 28 s |
| WhisperKit Small 216 MB | **+650 MB** (598–762) | +0.7–1.1 GB | 190 MB | 11.7 | 25 s |
| whisper.cpp Large-v3 Turbo q5_0 | +1,300 MB (1,295–1,322) | +1.4 GB | 922 MB | 4.3 | 14 s |
| whisper.cpp Large-v3 Turbo fp16 | +2,150 MB (2,055–2,214) | +2.4 GB | 2,013 MB | 4.7 | 16 s |

WhisperKit's process footprint (about 190 MB) hides roughly 800 MB held for it outside the process, which is why the system-wide measure matters: against whisper.cpp's quantised model WhisperKit Large uses roughly **300 MB less** system memory (at the edge of what this measure resolves), not the 700 MB less its process footprint suggests. Both keep every candidate far under 16 GB; the 8 GB question is untested.
WhisperKit is about 2× slower per recording (RTF about 0.05 against 0.025–0.03) and uses more CPU seconds. Thermal state stayed "nominal" in every run; these runs last under a minute, so **thermal behaviour over a long session is not measured**.

**Energy: not measured.** The kernel's per-process energy counters read 0.0–0.2 J for runs that used up to 12 s of CPU, and GPU/Neural Engine energy is not billed to the process; `powermetrics` is the only source and needs root. `spikes/asr/energy_session.sh` (run once by the owner with `sudo`, workload runs as the owner) records CPU, GPU and Neural Engine power for any command, and `parse_powermetrics.py` summarises it. The parser has not been run on real `powermetrics` output; if it fails, send the raw log.

**First-launch experience** (nothing cached): WhisperKit must download its model (626 MB Large, 216 MB Small; download time depends on the connection and was not timed) and Core ML compiles it once, **47 s for Large and 13 s for Small**; later launches load in 1.4 s and 0.7 s. whisper.cpp has no compile step (load 0.13–0.4 s) but needs a 574 MB (q5_0) download. A first-run progress step is therefore a requirement for WhisperKit and Large.

**Other languages (records only; English first, no claim).** Real Hindi (FLEURS, 40 utterances, 22 female and 18 male speakers, 464 s): WER **0.30** whisper.cpp (q5_0 and fp16) and **0.35** WhisperKit Large; character error 0.12 and 0.16. That is worse than the 0.18–0.22 on synthetic voices measured earlier, so **synthetic speech overstated Hindi accuracy**. WhisperKit with no language given detected Hindi on 34 of 40 clips (four as Urdu, two as English) and returned an empty transcript for one clip. Small is far weaker on synthetic Hindi (WER 0.39–0.48) and Hinglish scoring is dominated by script convention (31 % of reference words are Latin script, written in Devanagari by the models). These are the baseline for the later language phase.

**What would make WhisperKit's lead real:** creator English speech (noisy rooms, screen-recording narration, technical terms), the energy and long-session thermal runs, and an 8 GB result. Against it: slower, a first-launch compile, and a dependency on Argmax's package and a moving Hugging Face model reference (`main`; pinned here per file by SHA-256).

Harness errors found and fixed while measuring (recorded because they produced wrong numbers): `-np` hid whisper.cpp's timing lines; a regular expression cut Devanagari words at vowel signs; the first parse of whisper.cpp's DTW output read the wrong field and the flag silently did nothing until flash attention was turned off.

## 6. Draft pass bars for the † features

The bars proposed earlier are now in `creator-media-evaluation.md` §5 as **provisional** (decision D2), with the reporting rules: per feature and per stratum, bootstrap intervals,
a candidate passes only if **every** stratum passes, and a corpus size and distractors are stated. This phase's COCO result (section 3) is the reason for the last rule: the same model scores
0.986 or 0.845 hit@10 depending only on corpus size.

## 7. Test material (data only; used locally, never committed or shipped)

| Set | What | Purpose | Licence note |
| --- | --- | --- | --- |
| COCO 5k test split (Karpathy) | all 5,000 images × 5 human captions (a fixed-seed 500-image sample was used first), from Hugging Face `nlphuji/mscoco_2014_5k_test_image_text_retrieval` | text→image and caption→caption; vector index on real vectors | Captions CC BY 4.0; images are Flickr photos, local measurement only |
| ESC-50 subset | 200 five-second clips, 4 per class × 50 classes | text→sound (S5 proxy) | CC BY-NC 4.0 (clips have their own licences); local measurement only |
| macOS speech set (`spikes/data-prep/make_tts_set.py`) | 40 utterances (169 s) with exact reference text, plus a 59.5 s timeline clip with known sentence starts | transcription WER and timestamp error | Made with macOS `say`; synthetic and cleaner than real speech |
| LibriSpeech test-clean | 40 real read utterances, archive md5 matches the published value; also joined into one 8.3-minute recording with 40 known sentence starts | real-speech WER and timestamp error | CC BY 4.0 |
| FLEURS Hindi test | 40 utterances sampled with a fixed seed from the 418-utterance test split (`google/fleurs`, archive SHA-256 equals the published id) | real Hindi speech (a record for the later language phase) | CC BY 4.0 |
| 200 photographs + 10 re-exported clips | from Phase 2 | near-duplicate precision/recall | see `docs/LICENSES.md` |

**Proxy sets are not the gate.** The plan requires each † feature to pass a set built from *real creator media*; these only compare runtimes and settings.

## 8. What I need

1. **Authorized creator media and queries, English first (D3).** Put files you made, licensed, or have written consent for in `~/Library/Developer/SmartAsset/phase3/data/creator/`, run `python3 -I spikes/creator-eval/ingest.py <that folder>`, fill the stratum, language and permission for each, write queries, then validate the annotated moments with the page `review.py` generates. Nothing is selected or passed without this.
2. **Energy (needed before Whisper adoption):** run `sudo spikes/asr/energy_session.sh <label> <command…>` once for WhisperKit Large and once for whisper.cpp q5_0 (the example in the script header). I will not use `sudo` myself.
3. **8 GB and 24–32 GB Macs**, or keep the standing decision that no support is claimed for them.
4. Agreement to the provisional pass bars once the first creator-media results exist.

**Open on my side, not blocked on you:** real XPC, memory pressure and a sandboxed helper (need the product build); a runtime network audit of both binaries outside the sandbox; a long-session thermal run; and a plan for the 20 images/s gate (image preparation with Accelerate or Core Image in the MLX path, which is Swift loops today).
