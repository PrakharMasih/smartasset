// What the embedding worker needs from a model (Phase 4, search by meaning). The worker and the app depend on this
// protocol, not on any runtime, so MLX Swift (or any other runtime) lives in one place and everything above it is
// tested with a stand-in.
import CoreBridge
import Foundation

public protocol EmbeddingModel: Sendable {
    /// What the vectors mean. Announced to Rust, which keeps vectors of different configurations apart.
    var config: ModelConfigDto { get }
    /// A question in words, as the model reads a search.
    func embed(query: String) async throws -> [Float]
    /// A picture file (a grid thumbnail).
    func embed(imageFile: URL) async throws -> [Float]
    /// A picture as raw pixels: 3 bytes per pixel (red, green, blue), row after row.
    func embed(rgb: [UInt8], width: Int, height: Int) async throws -> [Float]
    /// Refuses new calls and returns once the calls already running have finished. The app calls it before it quits:
    /// a process that exits while a model is mid-evaluation crashes as the runtime's global objects are torn down
    /// under it (crash reports of 8–9 Nov, all with the main thread inside `exit()`).
    func close() async
    /// C1: the cut-off a label word's vector must reach against a file's vector for the file to show that label; nil when
    /// it was never measured for this model (labels are then not shown).
    var labelMatch: Float? { get }
}

public extension EmbeddingModel {
    var labelMatch: Float? { nil }

    /// Stand-ins with nothing running in the background need no closing.
    func close() async {}
}
