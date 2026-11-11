// The experiment behind decision 6 (start in-process, keep XPC possible). Same provider, same work, run in this process and in a child:
//   - start-up cost and memory held by the app process,
//   - latency per call, and how late the main thread's 120 Hz timer fires while embedding runs (responsiveness),
//   - image throughput with 1, 2 and 4 requests in flight, and as a batch,
//   - memory returned after the provider is released,
//   - what happens when the provider process is killed with SIGKILL in the middle of work (reliability).
// Usage: <executable> [--serve]            (--serve: run as the child)   |   <executable> [--only inproc|child]
import BenchSupport
import Dispatch
import Foundation

/// Fires every 8 ms on the main queue and records how late each firing was (a stand-in for frame pacing of the UI).
final class LatenessMonitor: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var late: [Double] = []
    func start() {
        DispatchQueue.main.async {
            self.late = []
            var expected = now() + 8
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .nanoseconds(0))
            t.setEventHandler {
                let n = now()
                self.late.append(max(0, n - expected))
                expected += 8
                if expected < n { expected = n + 8 }
            }
            t.resume()
            self.timer = t
        }
    }
    func stop() async -> [String: Double] {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                self.timer?.cancel(); self.timer = nil
                let s = self.late.sorted()
                func p(_ q: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
                cont.resume(returning: ["ticks": Double(s.count), "p50_ms": p(0.5), "p99_ms": p(0.99), "max_ms": s.last ?? 0,
                                        "over_16ms": Double(s.filter { $0 > 16.7 }.count)])
            }
        }
    }
}

public enum ProviderBench {
    /// Entry point for a runtime's `provider-bench` executable.
    public static func main(name: String, make: @escaping @Sendable () -> any EmbeddingProvider) {
        if CommandLine.arguments.contains("--serve") {
            Task { await serveProvider(make()); exit(0) }
        } else {
            Task {
                do { try await run(name: name, make: make) } catch { log("ERROR: \(error)"); exit(1) }
                exit(0)
            }
        }
        dispatchMain()
    }

    struct Work: Sendable {
        let texts: [String]
        let images: [String]
    }

    static func loadWork(images count: Int) throws -> Work {
        let coco = try Datasets.coco()
        return Work(texts: coco.prefix(count).flatMap { $0.captions.prefix(1) },
                    images: coco.prefix(count).map { Datasets.cocoImage($0).path })
    }

    /// Runs the common workload against any provider and returns latencies and the main thread's lateness.
    static func workload(_ p: any EmbeddingProvider, _ w: Work, monitor: LatenessMonitor) async throws -> [String: Any] {
        var text = Samples(), image = Samples()
        monitor.start()
        for t in w.texts.prefix(30) { try await timed(&text) { _ = try await p.embed([.query(t)]) } }
        for path in w.images.prefix(30) { try await timed(&image) { _ = try await p.embed([.image(path: path, visionTokens: 70)]) } }
        let lateness = await monitor.stop()
        return ["text_single": text.summary, "image_70": image.summary, "main_thread_lateness": lateness]
    }

    /// Images per second with `c` requests in flight, over `paths`.
    static func throughput(_ p: any EmbeddingProvider, _ paths: [String], concurrency c: Int, batch: Int = 1) async throws -> Double {
        let t0 = now()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0, inFlight = 0
            while next < paths.count || inFlight > 0 {
                while inFlight < c && next < paths.count {
                    let slice = Array(paths[next..<min(next + batch, paths.count)]); next += slice.count; inFlight += 1
                    group.addTask { _ = try await p.embed(slice.map { .image(path: $0, visionTokens: 70) }) }
                }
                try await group.next(); inFlight -= 1
            }
        }
        return Double(paths.count) / ((now() - t0) / 1000)
    }

    static func run(name: String, make: @escaping @Sendable () -> any EmbeddingProvider) async throws {
        let only = CommandLine.arguments.drop { $0 != "--only" }.dropFirst().first
        let work = try loadWork(images: 48)
        var report: [String: Any] = ["runtime": name, "machine_thermal_start": thermalState()]
        let monitor = LatenessMonitor()

        // Baseline: how late the timer is with nothing running.
        monitor.start(); try await Task.sleep(for: .seconds(3))
        report["idle_main_thread_lateness"] = await monitor.stop()

        // ---- in-process
        if only == nil || only == "inproc" {
            var section: [String: Any] = [:]
            let f0 = physFootprintMB()
            var provider: (any EmbeddingProvider)? = make()
            let t0 = now()
            try await provider!.prepare()
            section["prepare_ms"] = now() - t0
            section["app_footprint_before_mb"] = f0
            section["app_footprint_after_prepare_mb"] = physFootprintMB()
            section.merge(try await workload(provider!, work, monitor: monitor)) { $1 }
            var tp: [String: Double] = [:]
            for c in [1, 2, 4] { tp["images_per_s_inflight_\(c)"] = try await throughput(provider!, work.images, concurrency: c) }
            tp["images_per_s_batch8"] = try await throughput(provider!, work.images, concurrency: 1, batch: 8)
            section["image_throughput"] = tp
            section["app_footprint_peak_mb"] = peakFootprintMB()
            await provider!.shutdown(); provider = nil
            try await Task.sleep(for: .seconds(2))
            section["app_footprint_after_release_mb"] = physFootprintMB()
            section["thermal_at_end"] = thermalState()
            report["in_process"] = section
            log("in-process done: \(section["image_throughput"] ?? "")")
        }

        // ---- child process
        if only == nil || only == "child" {
            var section: [String: Any] = [:]
            let remote = RemoteProvider(name: name)
            let f0 = physFootprintMB()
            try remote.start()
            let t0 = now()
            try await remote.prepare()
            section["prepare_ms_including_process_start"] = now() - t0
            section["app_footprint_before_mb"] = f0
            section["app_footprint_after_prepare_mb"] = physFootprintMB()
            section["child_footprint_mb"] = await remote.footprintMB()
            section.merge(try await workload(remote, work, monitor: monitor)) { $1 }
            var tp: [String: Double] = [:]
            for c in [1, 2, 4] { tp["images_per_s_inflight_\(c)"] = try await throughput(remote, work.images, concurrency: c) }
            tp["images_per_s_batch8"] = try await throughput(remote, work.images, concurrency: 1, batch: 8)
            section["image_throughput"] = tp
            section["child_footprint_peak_mb"] = await remote.footprintMB()
            section["app_footprint_peak_mb"] = peakFootprintMB()

            // Reliability: kill the child with SIGKILL while a long request is running.
            var rel: [String: Any] = [:]
            let killAt = now()
            let work8 = Array(work.images.prefix(40))
            let inflight = Task { () -> String in
                do { _ = try await remote.embed(work8.map { .image(path: $0, visionTokens: 70) }); return "completed" }
                catch { return "\(error)" }
            }
            try await Task.sleep(for: .milliseconds(400))
            remote.kill9()
            let outcome = await inflight.value
            rel["in_flight_request_outcome"] = outcome
            rel["ms_from_kill_to_error_seen"] = now() - killAt - 400
            let r0 = now()
            try remote.restart()
            try await remote.prepare()
            rel["ms_to_restart_and_prepare"] = now() - r0
            let v = try await remote.embed([.query("a dog on a beach")])
            rel["next_request_ok"] = v.first?.count == 768
            rel["app_survived"] = true
            section["after_kill9"] = rel
            await remote.shutdown()
            try await Task.sleep(for: .seconds(1))
            section["app_footprint_after_child_exit_mb"] = physFootprintMB()
            section["thermal_at_end"] = thermalState()
            report["child_process"] = section
            log("child done: \(section["image_throughput"] ?? "")")
        }

        let dest = Bench.results("provider/\(name).json")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: dest)
        log("written \(dest.path)")
    }
}
