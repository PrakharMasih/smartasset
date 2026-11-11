// The seam. Everything that crosses it is a plain value (text, file paths, numbers, float vectors): no media bytes, no runtime
// objects. That is what lets the same calls run in this process today and across an XPC connection later.
import Foundation

public enum EmbeddingInput: Sendable, Codable, Equatable {
    case query(String)                         // text used to search
    case document(String)                      // text being indexed
    case image(path: String, visionTokens: Int)
    case audio(path: String)
}

public enum ProviderError: Error, Sendable, CustomStringConvertible {
    case processDied(String)                   // the child went away (crash, kill, memory pressure)
    case failed(String)                        // the runtime refused or failed this request
    case protocolError(String)
    public var description: String {
        switch self {
        case .processDied(let s): "provider process died: \(s)"
        case .failed(let s): "provider failed: \(s)"
        case .protocolError(let s): "provider protocol error: \(s)"
        }
    }
}

public protocol EmbeddingProvider: Sendable {
    /// What this provider is, for logs and the Models tab.
    var name: String { get }
    /// Loads the models. Idempotent. The slow, memory-hungry step; callers decide when it happens.
    func prepare() async throws
    /// One 768-dimensional, unit-length vector per input, in order. A provider may run inputs as a batch or one by one.
    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]]
    /// Releases the models. For a child-process provider this ends the process, which returns all of its memory at once.
    func shutdown() async
    /// Memory this provider holds, in MB: the process footprint in-process, the child's footprint out of process.
    func footprintMB() async -> Double
}
