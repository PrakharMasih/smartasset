// Downloading a model (plan H5), the only networking code in SmartAsset (tools/audit-network.sh allows it in this file
// and nowhere else). Owner's rules, 2026-11-09:
//  * only when the person chooses Download Model, after seeing name, publisher, version, size and disk space needed;
//  * only the pinned files (PinnedModels) at their pinned commit on Hugging Face, over HTTPS; redirects only to Hugging
//    Face's own hosts; an ephemeral session (no cookies, no cache), no extra headers, nothing about the library is sent;
//  * every file is checked against its SHA-256 before anything is installed; files go to a staging folder beside the
//    final one, and the whole model is moved into place in one step;
//  * no update checks, no background downloads, no telemetry. Once installed, nothing here runs again.
import AppKit
import Embedding
import Foundation
import SmartAssetKit

@MainActor
@Observable
final class ModelDownload {
    enum State: Equatable {
        case notInstalled
        /// Bytes of the whole model received so far.
        case downloading(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    let model: PinnedModel
    private(set) var state: State = .notInstalled
    /// Called once a model was installed (the app then loads it) or removed (the app stops using it).
    @ObservationIgnored var onInstalled: (() -> Void)?
    @ObservationIgnored var onRemoved: (() async -> Void)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var current: URLSessionDownloadTask?

    init(model: PinnedModel) {
        self.model = model
        refresh()
    }

    static var modelsRoot: URL { SemanticModels.modelsRoot }
    var installFolder: URL { Self.modelsRoot.appending(path: model.folder, directoryHint: .isDirectory) }
    /// Beside the final folder, on the same volume, so installing is a move, never a copy.
    private var stagingFolder: URL { Self.modelsRoot.appending(path: ".download-\(model.id)", directoryHint: .isDirectory) }

    func refresh() {
        if case .downloading = state { return }
        state = ModelFiles.isInstalled(model, in: installFolder) ? .installed : .notInstalled
    }

    /// Free space on the volume that will hold the model, or nil if it cannot be read.
    var freeBytes: Int64? {
        var probe = Self.modelsRoot
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    var hasRoom: Bool { (freeBytes ?? .max) >= model.requiredFreeBytes }

    /// Starts the download. Only ever called from the person's own Download button.
    func start() {
        guard work == nil else { return }
        guard hasRoom else {
            state = .failed("There isn’t enough free space. \(model.name) needs \(Self.size(model.requiredFreeBytes)) free.")
            return
        }
        state = .downloading(received: 0, total: model.totalBytes)
        work = Task { [weak self] in
            await self?.run()
            self?.work = nil
        }
    }

    /// Stops the download. Files already downloaded and checked are kept in the staging folder, so starting again
    /// fetches only the rest; nothing is installed.
    func cancel() {
        work?.cancel()
        current?.cancel()
    }

    /// Removes the installed model (the files are SmartAsset's own download, so they are deleted, not moved to the Trash).
    func remove() async {
        await onRemoved?()
        try? FileManager.default.removeItem(at: installFolder)
        try? FileManager.default.removeItem(at: stagingFolder)
        refresh()
    }

    private func run() async {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            let session = URLSession(configuration: Self.sessionConfiguration, delegate: RedirectGuard(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var done: Int64 = 0
            for file in model.files {
                try Task.checkCancellation()
                // Downloaded and checked before (an earlier, interrupted download): keep it.
                if try ModelFiles.check(file, in: stagingFolder) == nil {
                    done += file.bytes
                    state = .downloading(received: done, total: model.totalBytes)
                    continue
                }
                guard let url = model.url(for: file) else { throw DownloadError.message("The address of \(file.path) is not valid.") }
                let target = stagingFolder.appending(path: file.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = done
                try await fetch(url, to: target, session: session) { [weak self] received in
                    guard let self else { return }
                    self.state = .downloading(received: before + received, total: self.model.totalBytes)
                }
                if let problem = try ModelFiles.check(file, in: stagingFolder) {
                    try? fm.removeItem(at: target)
                    throw DownloadError.message(Self.describe(problem))
                }
                done += file.bytes
            }
            state = .verifying
            let problems = try await Task.detached { [model, stagingFolder] in try ModelFiles.problems(model, in: stagingFolder) }.value
            if let first = problems.first { throw DownloadError.message(Self.describe(first)) }
            try ModelFiles.install(model, from: stagingFolder, to: installFolder)
            state = .installed
            onInstalled?()
        } catch is CancellationError {
            state = .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            state = .notInstalled
        } catch let error as DownloadError {
            state = .failed(error.text)
        } catch let error as URLError {
            state = .failed(Self.describe(error))
        } catch {
            state = .failed("The model couldn’t be downloaded: \(error.userMessage)")
        }
        current = nil
    }

    /// One file over HTTPS into `target`; `progress` gets the bytes of this file received so far.
    private func fetch(_ url: URL, to target: URL, session: URLSession, progress: @escaping @MainActor (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { temporary, response, error in
                    // The temporary file is deleted when this returns: move it now.
                    if let error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let temporary else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.resume(throwing: DownloadError.message("Hugging Face answered \(code) for \(url.lastPathComponent). Try again later."))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: temporary, to: target)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let observation = task.progress.observe(\.completedUnitCount) { p, _ in
                    let received = p.completedUnitCount
                    Task { @MainActor in progress(received) }
                }
                objc_setAssociatedObject(task, &Self.observationKey, observation, .OBJC_ASSOCIATION_RETAIN)
                current = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.current?.cancel() }
        }
    }

    nonisolated(unsafe) private static var observationKey: UInt8 = 0

    /// No cookies, no cache, no stored credentials: nothing outlives the download or identifies the person.
    private static var sessionConfiguration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return c
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static func describe(_ problem: ModelFiles.Problem) -> String {
        switch problem {
        case .missing(let path): "\(path) was not downloaded. Nothing was installed; try again."
        case .wrongSize(let path): "\(path) arrived with the wrong size. Nothing was installed; try again."
        case .wrongChecksum(let path): "\(path) did not match its published checksum, so it was deleted and nothing was installed."
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "This Mac is offline. Connect to the internet and try again."
        case .timedOut: "Hugging Face took too long to answer. Try again later."
        case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            "The secure connection to Hugging Face could not be checked, so nothing was downloaded."
        default: "The model couldn’t be downloaded (\(error.code.rawValue)). Try again later."
        }
    }

    private enum DownloadError: Error {
        case message(String)
        var text: String { if case .message(let t) = self { return t }; return "" }
    }
}

/// Follows a redirect only to Hugging Face's own hosts over HTTPS (it serves large files from its CDN); anything else
/// stops the download.
private nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, PinnedModels.allowsRedirect(to: url) else { completionHandler(nil); return }
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }
}
