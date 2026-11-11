// The thin, typed Swift layer over the generated Rust bridge (docs/BRIDGE.md).
//
// Everything the app and the workers know about the Rust core comes through this module.

@_exported import CoreBridgeGenerated
import Foundation
import os

// MARK: - Events

/// Fans the engine's single callback out to any number of async streams.
///
/// The Rust engine delivers coalesced events on its own thread. Each subscriber gets its own `AsyncStream`,
/// so the UI and the media worker can both listen without stealing events from each other.
public final class EventHub: EngineListener, Sendable {
    private let continuations = OSAllocatedUnfairLock<[UUID: AsyncStream<EngineEvent>.Continuation]>(initialState: [:])

    public init() {}

    /// A new stream of every event from now on. It ends when the consumer stops iterating.
    public func stream() -> AsyncStream<EngineEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [continuations] _ in
                _ = continuations.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    public func onEvent(event: EngineEvent) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(event) }
    }

    /// Ends every stream (the engine is going away).
    public func finish() {
        let targets = continuations.withLock { state -> [AsyncStream<EngineEvent>.Continuation] in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        for continuation in targets { continuation.finish() }
    }
}

// MARK: - Opening

/// A running engine together with its event hub.
public struct CoreEngine: Sendable {
    public let handle: EngineHandle
    public let events: EventHub

    public init(handle: EngineHandle, events: EventHub) {
        self.handle = handle
        self.events = events
    }
}

public enum CoreBridge {
    /// Opens the library in `dataDirectory`. Browsing and search work right away; call `handle.start()` to begin
    /// watching and indexing.
    public static func open(
        dataDirectory: URL,
        workerParallelism: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        watch: Bool = true
    ) async throws -> CoreEngine {
        let hub = EventHub()
        let options = EngineOptions(
            dataDir: dataDirectory.path,
            workerParallelism: UInt32(clamping: workerParallelism),
            watch: watch
        )
        let handle = try await openEngine(options: options, listener: hub)
        return CoreEngine(handle: handle, events: hub)
    }
}

// MARK: - Queries

public extension SearchQuery {
    /// The whole library, newest first.
    static var everything: SearchQuery { defaultSearchQuery() }

    /// The same query restricted by `change`.
    func filtered(_ change: (inout Filters) -> Void) -> SearchQuery {
        var copy = self
        change(&copy.filters)
        return copy
    }

    /// True when nothing narrows the library.
    var isUnfiltered: Bool {
        text?.trimmingCharacters(in: .whitespaces).isEmpty ?? true && filters == SearchQuery.everything.filters
    }
}

public extension MediaKind {
    var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

extension AssetSummaryDto: Identifiable {}
extension FolderDto: Identifiable {}
extension CollectionDto: Identifiable {}
extension SmartCollectionDto: Identifiable {}
extension TagDto: Identifiable {}

public extension ProbeDto {
    /// A probe with nothing known yet; fill in what the decoder finds.
    static var empty: ProbeDto {
        ProbeDto(width: nil, height: nil, durationMs: nil, codec: nil, fps: nil, sampleRate: nil, channels: nil,
                 bitrate: nil, captureAt: nil, cameraMake: nil, cameraModel: nil, lens: nil, gpsLat: nil, gpsLon: nil,
                 exifJson: nil)
    }
}

// MARK: - Errors

public extension Error {
    /// A sentence fit to show a person. The generated error text is a debug dump (`BridgeError.Refused(message: …)`),
    /// so anything shown in the interface goes through this instead of `localizedDescription`.
    var userMessage: String {
        guard let bridge = self as? BridgeError else { return localizedDescription }
        switch bridge {
        case .NotFound(let message), .Invalid(let message), .Database(let message), .Io(let message),
             .SchemaTooNew(let message), .Corrupt(let message), .Refused(let message), .Internal(let message):
            return message
        case .Cancelled:
            return "Cancelled."
        }
    }
}
