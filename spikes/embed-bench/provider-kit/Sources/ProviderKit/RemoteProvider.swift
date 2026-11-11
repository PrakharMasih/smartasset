// Client side of the stand-in transport: starts this same executable with --serve and talks to it over pipes. One request at a
// time, on a serial queue (blocking I/O stays off Swift's cooperative threads). Real XPC would add its own per-call cost: this measures
// the floor, and the isolation properties (crash containment, memory returned on exit) are the same.
import Foundation

public final class RemoteProvider: EmbeddingProvider, @unchecked Sendable {
    public let name: String
    private let queue = DispatchQueue(label: "provider.remote.io")
    private var process: Process?
    private var toChild: Int32 = -1
    private var fromChild: Int32 = -1
    private var lastFootprint = 0.0
    public private(set) var childPID: Int32 = 0

    public init(name: String) { self.name = name + " (child process)" }

    public func start() throws {
        try queue.sync { try startLocked() }
    }

    private func startLocked() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--serve"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.standardError
        try p.run()
        childPID = p.processIdentifier
        process = p
        toChild = input.fileHandleForWriting.fileDescriptor
        fromChild = output.fileHandleForReading.fileDescriptor
        // keep the handles alive for the life of the process
        keep = [input, output]
    }
    private var keep: [Pipe] = []

    /// Kills the child abruptly (what a crash or the system's memory-pressure killer looks like to the parent).
    public func kill9() { if childPID > 0 { kill(childPID, SIGKILL) } }
    public var isAlive: Bool { queue.sync { process?.isRunning ?? false } }

    /// Starts a fresh child after the old one died.
    public func restart() throws { try queue.sync { closeLocked(); try startLocked() } }

    private func closeLocked() {
        process?.terminate(); process?.waitUntilExit(); process = nil; keep = []; toChild = -1; fromChild = -1
    }

    private func call(_ kind: UInt8, _ payload: Data) throws -> Data {
        guard process?.isRunning == true else { throw ProviderError.processDied("not running") }
        var body = Data([kind]); body.append(payload)
        guard Wire.writeFrame(toChild, body) else { throw ProviderError.processDied("write failed") }
        guard let frame = Wire.readFrame(fromChild), frame.count >= 9 else {
            process?.waitUntilExit()
            throw ProviderError.processDied("exit status \(process?.terminationStatus ?? -1), reason \(process?.terminationReason.rawValue ?? -1)")
        }
        lastFootprint = Double(bitPattern: frame.load(UInt64.self, at: 1))
        let rest = frame.dropFirst(9)
        if frame[0] != Wire.ok { throw ProviderError.failed(String(decoding: rest, as: UTF8.self)) }
        return Data(rest)
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    public func prepare() async throws { _ = try await run { try self.call(Wire.prepare, Data()) } }

    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        let json = try JSONEncoder().encode(inputs)
        let data = try await run { try self.call(Wire.embed, json) }
        guard data.count >= 8 else { throw ProviderError.protocolError("short reply") }
        let n = Int(data.load(UInt32.self, at: 0)), dims = Int(data.load(UInt32.self, at: 4))
        guard data.count == 8 + n * dims * 4 else { throw ProviderError.protocolError("bad vector payload") }
        return (0..<n).map { i in
            (0..<dims).map { j in Float(bitPattern: data.load(UInt32.self, at: 8 + (i * dims + j) * 4)) }
        }
    }

    public func shutdown() async {
        _ = try? await run { try self.call(Wire.shutdown, Data()) }
        queue.sync { closeLocked() }
    }

    public func footprintMB() async -> Double {
        _ = try? await run { try self.call(Wire.footprint, Data()) }
        return queue.sync { lastFootprint }
    }
}
