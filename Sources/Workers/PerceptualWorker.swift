// The pull loop for perceptual hashes (plan A2, §6.3): next_perceptual_batch → describe → submit_perceptual_results.
// Same shape and the same politeness as the media worker; Rust hands out nothing until the thumbnails are done.
import CoreBridge
import Foundation

public final class PerceptualWorker: Sendable {
    private let engine: EngineHandle
    private let events: EventHub
    private let task = LockedBox<Task<Void, Never>?>(nil)
    private let wake = WakeSignal()
    private let maxItems: UInt32

    public init(engine: EngineHandle, events: EventHub, maxItemsPerBatch: UInt32 = 32) {
        self.engine = engine
        self.events = events
        self.maxItems = maxItemsPerBatch
    }

    public func start() {
        task.withLock { current in
            guard current == nil else { return }
            current = Task.detached(priority: .background) { [self] in await run() }
        }
    }

    /// Stops after the current item; unfinished work goes back to the queue.
    public func stop() async {
        let running = task.withLock { current -> Task<Void, Never>? in
            let t = current
            current = nil
            return t
        }
        running?.cancel()
        await running?.value
    }

    private func run() async {
        let forwarder = Task.detached(priority: .background) { [events, wake] in
            for await event in events.stream() {
                switch event {
                case .progress(let p) where p.dedupeRemaining > 0 || p.mediaRemaining == 0: await wake.signal()
                case .libraryChanged: await wake.signal()
                default: break
                }
            }
        }
        defer { forwarder.cancel() }

        var failures = 0
        while !Task.isCancelled {
            do {
                switch try await engine.nextPerceptualBatch(maxItems: maxItems) {
                case .batch(let batch):
                    failures = 0
                    await process(batch)
                case .held:
                    await wake.wait(timeout: .seconds(5))
                case .empty:
                    await wake.wait(timeout: .seconds(30))
                }
            } catch {
                failures += 1
                await wake.wait(timeout: .seconds(min(30, 2 * failures)))
            }
        }
    }

    private func process(_ batch: PerceptualBatchDto) async {
        let tasks = batch.tasks
        let width = max(1, Int(batch.parallelism))
        let batchId = batch.batchId
        let engine = self.engine
        var results: [PerceptualResultDto] = []
        results.reserveCapacity(tasks.count)
        var lastHeartbeat = ContinuousClock.now

        await withTaskGroup(of: PerceptualResultDto.self) { group in
            var next = 0
            func launch() {
                guard next < tasks.count else { return }
                let item = tasks[next]
                next += 1
                group.addTask(priority: .background) {
                    PerceptualResultDto(jobId: item.jobId, outcome: await PerceptualProcessor.processWithTimeout(item))
                }
            }
            for _ in 0..<min(width, tasks.count) { launch() }
            while let result = await group.next() {
                results.append(result)
                if !engine.isBatchRevoked(batchId: batchId), !Task.isCancelled { launch() }
                if lastHeartbeat.duration(to: .now) > .seconds(20) {
                    lastHeartbeat = .now
                    _ = try? await engine.heartbeat(batchId: batchId)
                }
            }
        }
        _ = try? await engine.submitPerceptualResults(batchId: batchId, results: results)
    }
}
