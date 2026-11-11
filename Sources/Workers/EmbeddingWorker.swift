// The pull loop for vectors (Phase 4, plan §6.3): next_embedding_batch → embed → submit_embedding_results.
// Same shape and the same politeness as the other workers. The model is one GPU: items go one at a time (measured
// in Phase 3: concurrent images raised throughput only from 16 to 19 a second, at the cost of heat and memory).
import CoreBridge
import Foundation

public final class EmbeddingWorker: Sendable {
    private let engine: EngineHandle
    private let events: EventHub
    private let model: any EmbeddingModel
    private let task = LockedBox<Task<Void, Never>?>(nil)
    private let wake = WakeSignal()
    private let maxItems: UInt32

    public init(engine: EngineHandle, events: EventHub, model: any EmbeddingModel, maxItemsPerBatch: UInt32 = 16) {
        self.engine = engine
        self.events = events
        self.model = model
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
                case .progress(let p) where p.embedRemaining > 0 || p.mediaRemaining == 0: await wake.signal()
                case .libraryChanged: await wake.signal()
                default: break
                }
            }
        }
        defer { forwarder.cancel() }

        var failures = 0
        while !Task.isCancelled {
            do {
                switch try await engine.nextEmbeddingBatch(maxItems: maxItems) {
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

    private func process(_ batch: EmbeddingBatchDto) async {
        let batchId = batch.batchId
        var results: [EmbeddingResultDto] = []
        results.reserveCapacity(batch.tasks.count)
        var lastHeartbeat = ContinuousClock.now
        for item in batch.tasks {
            // Revoked (paused, folder removed) or quitting: hand back what is done; the rest returns to the queue.
            if engine.isBatchRevoked(batchId: batchId) || Task.isCancelled { break }
            results.append(EmbeddingResultDto(jobId: item.jobId, outcome: await EmbeddingProcessor.processWithTimeout(item, model: model)))
            if lastHeartbeat.duration(to: .now) > .seconds(20) {
                lastHeartbeat = .now
                _ = try? await engine.heartbeat(batchId: batchId)
            }
        }
        _ = try? await engine.submitEmbeddingResults(batchId: batchId, results: results)
    }
}
