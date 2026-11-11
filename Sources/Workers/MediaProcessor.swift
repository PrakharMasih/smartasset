// One entry point per file: metadata + thumbnail, with every failure classified (plan §6.6).
import CoreBridge
import Foundation

public enum MediaProcessor {
    /// Seconds an item may take before the worker gives up on it and moves on.
    static func timeout(for kind: MediaKind) -> Duration {
        switch kind {
        case .image: .seconds(45)
        case .video: .seconds(90)
        case .audio: .seconds(120)
        }
    }

    /// Reads one file and writes its thumbnail to `task.thumbPath`. Never throws: a failure is a result.
    public static func process(_ task: MediaTaskDto) async -> MediaOutcomeDto {
        do {
            let (probe, wrote): (ProbeDto, Bool)
            switch task.kind {
            case .image: (probe, wrote) = try ImageProcessor.process(task)
            case .video: (probe, wrote) = try await VideoProcessor.process(task)
            case .audio: (probe, wrote) = try await AudioProcessor.process(task)
            }
            return .done(probe: probe, thumbWritten: wrote)
        } catch {
            let (errorClass, message) = ErrorClassifier.classify(error)
            // A cancelled item is not a failure of the file.
            return .failed(class: Task.isCancelled ? .transient : errorClass, message: message)
        }
    }

    /// Like `process`, but a decoder that hangs on a damaged file cannot stall the batch.
    public static func processWithTimeout(_ task: MediaTaskDto) async -> MediaOutcomeDto {
        let limit = timeout(for: task.kind)
        return await withCheckedContinuation { (continuation: CheckedContinuation<MediaOutcomeDto, Never>) in
            let once = Once(continuation)
            Task.detached(priority: .utility) { once.resume(with: await process(task)) }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: limit)
                once.resume(with: .failed(class: .transient, message: "Reading this file took too long."))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of two racers gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaOutcomeDto, Never>?

    init(_ continuation: CheckedContinuation<MediaOutcomeDto, Never>) { self.continuation = continuation }

    func resume(with value: MediaOutcomeDto) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
