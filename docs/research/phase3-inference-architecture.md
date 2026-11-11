# Inference architecture: start in-process, stay able to move out (owner decision 6, 2026-11-07)

**Decision (owner):** start with inference **in-process**, behind a **provider interface** that permits migration to XPC. Benchmark isolation, responsiveness,
memory pressure and reliability **before finalising** the process architecture. Plan §6.9 stays open until then.

This note defines the interface, reports what the prototype measured, and lists what is still unmeasured. The runtime comparison it uses is in
`phase3-model-spikes.md` §2; raw output is in `phase3-results/`. Machine: MacBook Air M5, 16 GB, one run per figure.

## 1. The interface (`spikes/embed-bench/provider-kit`, prototype)

```swift
public enum EmbeddingInput: Sendable, Codable {
    case query(String), document(String)
    case image(path: String, visionTokens: Int)
    case audio(path: String)
}
public protocol EmbeddingProvider: Sendable {
    var name: String { get }
    func prepare() async throws                            // load models; idempotent; the slow, memory-hungry step
    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]]   // 768-d, unit length, in order
    func shutdown() async                                  // release models (child process: end the process)
    func footprintMB() async -> Double
}
```

Rules that keep it movable:
- **Only plain values cross it:** text, file paths, numbers, float vectors. No media bytes (consistent with the Rust bridge rule), no runtime objects, no closures.
  Everything is `Sendable` and `Codable`, so the same calls can be encoded onto an XPC connection unchanged.
- **Errors are values the caller can act on:** `processDied` (retry after restart), `failed` (this input is bad), `protocolError`.
- **The caller decides when `prepare()` happens**, because it costs 0.4–1.3 s and 440–1,200 MB.
- **Two implementations of the same protocol per runtime:** the runtime in this process, and `RemoteProvider`, which runs the same executable as a child and speaks a
  length-prefixed binary protocol over two pipes. In the prototype the child is started with `--serve`; in the product it would be an XPC service.
- Where it sits in the plan: behind the Swift media workers' pull loop (`next_media_batch` / `submit_media_results`). Rust never learns which process embedded a file.

## 2. What the prototype measured (LiteRT-LM and MLX, each in-process and in a child process)

The same workload through the same interface: 30 single queries, 30 images (70 vision tokens), then 48 images with 1, 2 and 4 requests in flight and as a batch of 8.
`phase3-results/provider-*.json`.

| | LiteRT-LM in-process | LiteRT-LM child | MLX in-process | MLX child |
| --- | --- | --- | --- | --- |
| Start (`prepare`, includes starting the child) | 0.58 s | 1.32 s | 1.29 s | 1.29 s |
| App process footprint after prepare | 440 MB | **74 MB** | 1,211 MB | **207 MB** |
| Peak footprint of the process holding the model | 650 MB | 648 MB (child) | 1,554 MB | 1,366 MB (child) |
| Text query p50 | 17.3 ms | 17.1 ms | 10.3 ms | 10.8 ms |
| Image p50 | 101.2 ms | 99.7 ms | 63.0 ms | 60.9 ms |
| Main-thread timer lateness while embedding (p99; ticks over 16.7 ms) | 1.99 ms; 0 of 455 | 2.00 ms; 0 of 522 | 2.01 ms; 0 of 279 | 1.98 ms; 0 of 946 |
| Images/s: 1 / 2 / 4 in flight / batch of 8 | 10.0 / 10.1 / 10.1 / 10.1 | 10.1 / 10.1 / 10.1 / 10.1 | 16.5 / 19.1 / 19.1 / 18.5 | 16.8 / 16.7 / 16.8 / 18.4 |
| Footprint after the provider is released | 74 MB | (child gone) | 207 MB | (child gone) |
| `kill -9` of the model process mid-request: error seen / restart + `prepare` / next request | n/a (the app dies) | 75 ms / 0.37 s / ok | n/a (the app dies) | 104 ms / 1.13 s / ok |

What the numbers support:
1. **The process hop costs nothing measurable here.** Per-call latency through the child is within 2 ms of in-process for text and images (differences are inside run-to-run noise). The pipe stand-in is a floor: real
   XPC adds its own per-call cost, expected small against 10–100 ms of inference, but **not measured**.
2. **Main-thread responsiveness was not affected in either design:** the main thread's 120 Hz timer fired within 2 ms, as it does when idle. This measures main-thread scheduling only (see section 3).
3. **Memory ownership is the real difference.** In a child process the app stays at 74 or 207 MB while the model occupies 420 MB or 1.2 GB elsewhere; when the child exits all of it returns at once. In-process, releasing the
   models left 74 MB (LiteRT) and 207 MB (MLX) behind in the app. The MLX runtime needs about 2.7× the memory of LiteRT with the same three towers loaded (1.2 GB against 0.44 GB); that, not speed, is what decides
   whether it can run on an 8 GB Mac (untested).
4. **Reliability favours isolation.** A model process killed with SIGKILL mid-request surfaced as an error in about 0.1 s, the app kept running, and the next request succeeded after a 0.4–1.1 s restart. In-process, the
   same event is the app's own crash. This test cannot be run in-process without ending the process, so the in-process side is by construction.
5. **Concurrency does not help LiteRT at all** (its engine is a serial actor: 10.0–10.1 images/s however the requests are issued). MLX gains about 16 % (16.5 to 19.1/s) when the next image is prepared while the GPU is working,
   which needs the preparation outside the runtime's serial actor, as the adapter does. **Both stay below the Phase 4 gate of 20 images/s** on these 640×480 images; real photos add decode time.

6. **The app's grid stayed smooth while a model embedded on the GPU in another process** (`tools/bench-grid.sh`, 250,000-file library, 3 runs each): scroll lateness p99 7.3–7.7 ms idle, **5.0 ms with LiteRT-LM embedding, 5.2–5.6 ms with MLX embedding**, no tick more than 8 ms late under load (idle: 1–5 ticks). Lateness got *better* under load, which is most likely the machine leaving its power-saving state when busy, so the measure is a check that nothing got worse, not evidence of a benefit. Launch-to-ready was unchanged (about 350 ms; 410 ms with MLX). Limits: the library has no thumbnails (nothing decodes), and the metric is timer lateness.

## 3. What is not measured, and why it matters

- **Real XPC.** The stand-in is pipes between two processes. An XPC service needs an app bundle and a service registration, which the SwiftPM-only build here cannot produce; it is measured when the app target exists.
- **GPU frame pacing of the UI.** The grid benchmark below measures main-thread timer lateness while scrolling, not dropped frames. The GPU is shared by every process, so a separate process would not by itself keep the grid smooth; this needs Instruments or a frame-time probe in the real app with real thumbnails.
- **Memory pressure.** No test pushed the machine into pressure (and one should not be run casually on this Mac). What happens to an in-process model, to a child process, and to the app when memory runs low (and whether the system terminates the helper first) is open.
- **Thermal behaviour over a long indexing run.** All runs here are minutes long. The thermal state stayed "nominal" except after the 21-minute 5,000-image run, which ended "fair".
- **8 GB and 24–32 GB Macs.** Not available (plan §16). No support is claimed for them.
- **A child process under App Sandbox.** An XPC service can be sandboxed with no network entitlement, which would make "never connects" enforced by the system instead of promised. Both runtimes' binaries import networking
  functions (`phase3-model-spikes.md` §2), so this is a real security argument for the out-of-process design. It needs the signed, sandboxed product build to test.

## 4. Consequence for the decision

Nothing measured argues against starting in-process, and nothing in the interface prevents moving out. The measurements that would move the decision toward XPC are the ones that are open: UI smoothness under GPU
load, behaviour under memory pressure, and the sandboxing argument. Until they are measured, **build the Swift workers against `EmbeddingProvider`, run the runtime in-process first, and keep `RemoteProvider`'s
protocol (plain values, paths, vectors) as the shape of the eventual XPC contract.** Plan §6.9 remains open.
