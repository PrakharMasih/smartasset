import Foundation

/// Holds notification observers and removes them when the owner goes away, from any thread.
nonisolated final class ObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    nonisolated init() {}

    func add(_ token: NSObjectProtocol) {
        lock.lock(); tokens.append(token); lock.unlock()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
