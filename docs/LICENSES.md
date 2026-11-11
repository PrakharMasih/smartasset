# Licence register (plan §10.3)

First version, 2026-11-05. Checked before every release. **Nothing in the "To verify" rows may ship until it is verified.**

## Verified: Rust crates that ship in the app

Read from `cargo metadata` for the dependency closure of `sa-ffi` (128 third-party crates, normal dependencies only).
Re-run the same query before each release and compare.

| Licence | Crates | Obligation |
| --- | --- | --- |
| MIT, MIT OR Apache-2.0, Apache-2.0 OR MIT, MIT/Apache-2.0 | 108 (incl. `rusqlite`, `libsqlite3-sys`, `rayon`, `tokio`, `serde`, `tracing`, `crossbeam`, `parking_lot`) | Keep copyright and licence notices in the app's acknowledgements |
| Zlib, Zlib OR Apache-2.0 OR MIT | 3 (`foldhash`, `objc2-core-foundation`, `objc2-core-services`) | Notice |
| Unlicense OR MIT, Unlicense/MIT | 4 (`walkdir`, `same-file`, `aho-corasick`, `memchr`) | None (choose MIT, keep notice) |
| CC0-1.0 (and OR-combinations with Apache-2.0 / MIT-0) | 3 (`notify`, `blake3`, `constant_time_eq`) | None |
| **MPL-2.0** | 8 (`uniffi`, `uniffi_core`, `uniffi_macros`, `uniffi_meta`, `uniffi_bindgen`, `uniffi_internal_macros`, `uniffi_pipeline`, `uniffi_udl`) | File-level copyleft. Linked unmodified, so the obligation is to keep the notice and make the MPL source of those files available (the upstream repository, version-pinned in `Cargo.lock`). The generated Swift file is our build output, not an MPL file. **Never patch a `uniffi*` crate in place**; if a patch is needed, publish it |
| SQLite (bundled by `libsqlite3-sys`) | 1 | Public domain |

No GPL, LGPL or AGPL crate is in the shipped closure.

## Verified 2026-11-07 (Phase 3), from the repositories and model cards

| Component | Licence found | Notes |
| --- | --- | --- |
| EmbeddingGemma 2 weights (`google/embeddinggemma-2`) | **Apache 2.0** (card and repository metadata; ungated) | The card also states "Deployments must adhere to the **Gemma Prohibited Use Policy**" (`ai.google.dev/gemma/prohibited_use_policy`: categories include privacy and surveillance, such as unauthorised tracking or inferring sensitive information about people, and infringing outputs). The policy text says nothing about redistribution or flow-down. Not legal advice: have counsel confirm before shipping a model download |
| LiteRT-LM (`google-ai-edge/LiteRT-LM`) and its `.litertlm` EmbeddingGemma 2 bundles | Apache-2.0 | The macOS runtime is a prebuilt binary xcframework; its source licence is Apache-2.0 per the manifest header, but the binary's build is not independently reproducible here. **Found when run (2026-11-07):** the `libCLiteRTLM_mac.dylib` inside is only **ad-hoc signed** (no publisher identity), and it **imports socket, connect, bind, listen and getaddrinfo**. It ran correctly under a no-network sandbox, but that proves only that it does not need the network: the sandbox would have blocked any attempt silently, so whether it tries to connect is **not yet known**. A closed binary with networking symbols cannot be reconciled with the Privacy page's claim by inspection: it needs a runtime network audit (`tools/audit-network.sh`, with the binary running outside the sandbox) or a rebuild from source before it can ship |
| MLX Swift (`ml-explore/mlx-swift`), `ml-explore/mlx` (v0.32.2), `ml-explore/mlx-c` (v0.6.0+9) | MIT (LICENSE files read at the pinned commits) | Built from source in Phase 3. The build links code we would not use and that can open sockets or start processes: the Hugging Face download client (`NSURLSession`) via `swift-transformers`, MLX's distributed *ring* backend, and the CPU JIT (`popen`/`system`). Shipping MLX would need these removed or audited (see `phase3-model-spikes.md` §2) |
| Apple Metal Toolchain 27B47 | Apple software, installed with Xcode's own `xcodebuild -downloadComponent`; use is under the Xcode and Apple Developer terms | Build-time only (compiles MLX's shaders). The resulting `mlx.metallib` is MLX's MIT code compiled; the toolchain itself is not redistributed. Counsel to confirm the Xcode licence permits shipping compiled output (it ordinarily does) |
| `huggingface/swift-transformers` | Apache-2.0 | |
| `Obscyra-app/EmbeddingGemma2Swift` (community runtime) and its weights `Nurymanau/EmbeddingGemma-2-MLX-Swift` | MIT (code), Apache-2.0 (weights) | Third party, created 6 Oct 2026, one maintainer, 4 stars: **supply-chain risk**. Includes upstream `mlx-vlm` (MIT) and Pillow (HPND) licence files. Source reviewed 2026-11-07 |
| `argmaxinc/argmax-oss-swift` (WhisperKit) | MIT | |
| Silero VAD model for whisper.cpp (`ggml-org/whisper-vad`, `ggml-silero-v5.1.2.bin`) | MIT (Hugging Face metadata) | Used only in one Phase 3 experiment that did not work; not a candidate |
| `ggml-org/whisper.cpp` | MIT | v1.9.5, commit d1be6fde… Built from source with CMake under the Phase 3 sandbox; no Swift package, so a product use needs our own binding |
| `apple/swift-argument-parser` | Apache-2.0 with Runtime Library Exception | Only a manifest dependency of `argmax-oss-swift` (its command-line tool uses it); not linked by the WhisperKit library targets. v1.7.0, commit c5d11a80… |
| CMake | BSD-3-Clause | Build tool for whisper.cpp only (4.4.5, sha256 checked); never shipped |
| `tazz4843/whisper-rs` | Unlicense | **Archived** (last push 2025-07-30): not a candidate to depend on |
| OpenAI Whisper Large-v3 Turbo weights | MIT (model card) | |
| OpenAI Whisper Small weights | **Apache-2.0 per its Hugging Face card** (the original repository is MIT) | Corrects the register: not MIT on the card |

## To verify before anything ships

| Component | Reported licence | What must be confirmed |
| --- | --- | --- |
| EmbeddingGemma 2 (weights) | Apache 2.0 (verified, see above) | Counsel to confirm the Prohibited Use Policy wording and attribution text before the app offers a download (milestone M2) |
| Whisper Small / Large-v3 Turbo (weights) | MIT (OpenAI) | Source of the converted weights WhisperKit uses and *its* licence |
| WhisperKit | MIT (verified for `argmax-oss-swift`) | Confirm at the pinned version |
| whisper.cpp | MIT (verified) | Only if it wins the §7.4 benchmark; needs our own binding (`whisper-rs` is archived) |
| MLX Swift, LiteRT-LM | MIT, Apache-2.0 (verified) | Redistribution of the Metal shader library (`mlx.metallib`) with the app; LiteRT-LM binary provenance |
| FFmpeg (optional fallback) | LGPL or GPL by build | Dynamic linking, codec patents, exact `configure` flags. Not bundled |
| Swift runtime / system frameworks | Apple SDK licence | None beyond the SDK terms |

## Test material (never shipped, never committed)

| Material | Source | Use |
| --- | --- | --- |
| 200 photographs for the near-duplicate labeled set | picsum.photos (Unsplash photographs, Unsplash licence) | Downloaded to `~/Library/Developer/SmartAsset/fixtures/photos` by `tools/fetch-photo-fixtures.sh` and used only to measure matching on this Mac. They are not part of the repository or the app |
| 8 camera RAW files | raw.pixls.us (CC0) | Format tests (Phase 1) |
| COCO 5k test split (all 5,000 images, 25,000 captions; a 500-image sample for the first comparison) | Hugging Face `nlphuji/mscoco_2014_5k_test_image_text_retrieval` (captions CC BY 4.0; images are Flickr photos under their own licences) | Phase 3 runtime comparison, local measurement only |
| 200 ESC-50 sound clips (4 per class) | `karolpiczak/ESC-50` (CC BY-NC 4.0; clips have their own licences) | Phase 3 text→sound proxy, local measurement only. Non-commercial: never ship or redistribute |
| FLEURS Hindi test split (40 utterances used) | `google/fleurs` on Hugging Face (CC BY 4.0, ungated; archive SHA-256 equals the published id) | Phase 3 real-Hindi record for the later language phase; local measurement only |
| LibriSpeech test-clean (40 utterances used; also joined into one 8.3-minute test recording) | openslr.org (CC BY 4.0); archive md5 matches the published value | Phase 3 speech WER |
| Generated speech (macOS `say`) | Made on this Mac by `spikes/data-prep/make_tts_set.py` | Phase 3 WER and timestamp tests; synthetic, never shipped |

## Rules

- A dependency with an unknown or copyleft licence needs an entry here and an owner decision before it is added.
- The app's acknowledgements screen is generated from this register at release time.
