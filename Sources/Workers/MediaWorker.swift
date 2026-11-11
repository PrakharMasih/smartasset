// The pull loop (plan §6.3): next_batch → process → submit_results. Two bridge calls per batch.
import CoreBridge
import Foundation

/// Lets the loop sleep until something might have changed, instead of polling.
actor WakeSignal {
    private var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        if waiters.isEmpty {
            pending = true
        } else {
            let all = waiters
            waiters.removeAll()
            for (_, continuation) in all { continuation.resume() }
        }
    }

    func wait(timeout: Duration) async {
        if pending {
            pending = false
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[id] = continuation
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expire(id)
                }
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

public final class MediaWorker: Sendable {
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

    /// Starts the loop at utility priority, so decoding never competes with the UI.
    public func start() {
        task.withLock { current in
            guard current == nil else { return }
            current = Task.detached(priority: .utility) { [self] in await run() }
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
        // Wake when there may be new work: progress reports with work left, or changes to the library.
        let forwarder = Task.detached(priority: .utility) { [events, wake] in
            for await event in events.stream() {
                switch event {
                case .progress(let p) where p.mediaRemaining > 0: await wake.signal()
                case .libraryChanged: await wake.signal()
                default: break
                }
            }
        }
        defer { forwarder.cancel() }

        var failures = 0
        while !Task.isCancelled {
            do {
                switch try await engine.nextMediaBatch(maxItems: maxItems) {
                case .batch(let batch):
                    failures = 0
                    await process(batch)
                case .held:
                    await wake.wait(timeout: .seconds(5))
                case .empty:
                    await wake.wait(timeout: .seconds(30))
                }
            } catch {
                // The engine is closing or hit an error: back off rather than spin.
                failures += 1
                await wake.wait(timeout: .seconds(min(30, 2 * failures)))
            }
        }
    }

    private func process(_ batch: MediaBatchDto) async {
        let tasks = batch.tasks
        let width = max(1, Int(batch.parallelism))
        let batchId = batch.batchId
        let engine = self.engine
        var results: [MediaResultDto] = []
        results.reserveCapacity(tasks.count)
        var lastHeartbeat = ContinuousClock.now

        await withTaskGroup(of: MediaResultDto.self) { group in
            var next = 0
            func launch() {
                guard next < tasks.count else { return }
                let item = tasks[next]
                next += 1
                group.addTask(priority: .utility) {
                    MediaResultDto(jobId: item.jobId, outcome: await MediaProcessor.processWithTimeout(item))
                }
            }
            for _ in 0..<min(width, tasks.count) { launch() }
            while let result = await group.next() {
                results.append(result)
                // Stop starting new items once Rust revokes the batch or the worker is stopping.
                if !engine.isBatchRevoked(batchId: batchId), !Task.isCancelled { launch() }
                if lastHeartbeat.duration(to: .now) > .seconds(20) {
                    lastHeartbeat = .now
                    _ = try? await engine.heartbeat(batchId: batchId)
                }
            }
        }
        // One call returns everything finished; items not reported go back to the queue untouched.
        _ = try? await engine.submitMediaResults(batchId: batchId, results: results)
    }
}

/// A value guarded by a lock, shareable across tasks.
public final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
