// A tiny test harness with no macros, so it builds with Command Line Tools alone.
import Foundation

struct Failure: Error, CustomStringConvertible {
    let message: String
    let location: String
    var description: String { "\(location): \(message)" }
}

/// Fails the current test when `condition` is false.
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition() { throw Failure(message: message(), location: "\(file):\(line)") }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                               _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    let a = actual(), e = expected()
    if a != e { throw Failure(message: "\(message) expected \(e), got \(a)", location: "\(file):\(line)") }
}

/// A check that could not run here (a missing sample file or tool). Reported as UNVERIFIED, never as a pass.
struct Unverified: Error {
    let reason: String
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Failure {
    Failure(message: message, location: "\(file):\(line)")
}

struct TestCase: Sendable {
    let name: String
    let body: @Sendable () async throws -> Void
}

/// Polls until `condition` holds or the timeout passes.
func waitUntil(timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

/// A throwaway directory tree for a test.
struct Sandbox: Sendable {
    let root: URL
    let data: URL
    let media: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sa-test-\(UUID().uuidString)")
        data = root.appending(path: "data")
        media = root.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ content: String) throws {
        let url = media.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(repeating: content, count: 40).utf8).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
