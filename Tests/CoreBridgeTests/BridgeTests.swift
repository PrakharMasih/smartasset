import CoreBridge
import Foundation
import Testing

/// Tests that cross the real Rust ↔ Swift boundary (plan §11: bridge tests).
@Suite(.serialized)
struct BridgeTests {
    /// A throwaway library with a few files in it.
    struct Sandbox {
        let root: URL
        let data: URL
        let media: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "sa-bridge-\(UUID().uuidString)")
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

    static func volume() -> MountedVolumeDto {
        MountedVolumeDto(uuid: "TEST-VOLUME", name: "Test Disk", mountPath: "/", isInternal: true)
    }

    /// Polls until `condition` holds or the timeout passes.
    static func waitUntil(timeout: Duration = .seconds(20), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    @Test func opensAddsFolderAndPagesResults() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<50 { try sandbox.write("clip\(index).mov", "video \(index)") }
        for index in 0..<25 { try sandbox.write("shots/IMG_\(index).jpg", "photo \(index)") }

        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let info = engine.handle.openInfo()
        #expect(info.assetCount == 0)
        #expect(info.uncleanExit == false)
        try await engine.handle.start()

        let outcome = try await engine.handle.addFolder(
            request: AddFolderRequestDto(path: sandbox.media.path, bookmark: Data([1, 2, 3]), volume: Self.volume()))
        guard case .added(let folderId, let absorbed) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(absorbed.isEmpty)

        let handle = engine.handle
        let reached = await Self.waitUntil {
            ((try? await handle.search(query: .everything).count()) ?? 0) == 75
        }
        #expect(reached, "the browse pass lists every file")

        let results = try await handle.search(query: .everything)
        #expect(results.count() == 75)
        let firstPage = try await results.summaries(offset: 0, limit: 30)
        #expect(firstPage.count == 30)
        #expect(Set(firstPage.map(\.id)).count == 30, "no duplicates inside a page")
        let tail = try await results.summaries(offset: 70, limit: 100)
        #expect(tail.count == 5, "pages clamp to the end of the result")
        #expect(try await results.summaries(offset: 500, limit: 10).isEmpty)
        #expect(results.idAt(index: 0) == firstPage[0].id)
        #expect(results.indexOf(id: firstPage[7].id) == 7)

        let folders = try await handle.listFolders()
        #expect(folders.count == 1)
        #expect(folders[0].id == folderId)
        #expect(folders[0].bookmark == Data([1, 2, 3]))
        #expect(folders[0].path != nil)

        // Keyword search through the same bridge.
        var query = SearchQuery.everything
        query.text = "IMG_7"
        #expect(try await handle.search(query: query).count() == 1)
        try await handle.shutdown()
    }

    @Test func rustErrorsArriveAsTypedSwiftErrors() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)

        do {
            try await engine.handle.removeFolder(folderId: 4242)
            Issue.record("removing an unknown folder must throw")
        } catch let error as BridgeError {
            guard case .NotFound = error else { Issue.record("wrong case: \(error)"); return }
            #expect(error.localizedDescription.contains("folder"))
        }

        do {
            _ = try await engine.handle.addFolder(request: AddFolderRequestDto(
                path: sandbox.root.appending(path: "nope").path, bookmark: nil, volume: Self.volume()))
            Issue.record("adding a folder that does not exist must throw")
        } catch let error as BridgeError {
            guard case .Io = error else { Issue.record("wrong case: \(error)"); return }
        }

        do {
            try await engine.handle.setRating(assetIds: [], rating: 9)
            Issue.record("a rating of 9 must be rejected")
        } catch let error as BridgeError {
            guard case .Invalid = error else { Issue.record("wrong case: \(error)"); return }
        }
        try await engine.handle.shutdown()
    }

    @Test func hundredsOfConcurrentCallsAreSafe() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<200 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: Self.volume()))
        let ready = await Self.waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 200 }
        #expect(ready)

        let ids = try await handle.search(query: .everything).allIds()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<300 {
                group.addTask {
                    switch index % 3 {
                    case 0: return Int(try await handle.search(query: .everything).count())
                    case 1:
                        try await handle.setRating(assetIds: [ids[index % ids.count]], rating: UInt8(index % 6))
                        return 1
                    default: return try await handle.summaries(assetIds: Array(ids[0..<20])).count
                    }
                }
            }
            var total = 0
            for try await value in group { total += value }
            #expect(total > 0)
        }
        // Every rating write landed; the library is consistent.
        var rated = SearchQuery.everything
        rated.filters.minRating = 1
        #expect(try await handle.search(query: rated).count() > 0)
        try await handle.shutdown()
    }

    @Test func cancellingATaskDoesNotBreakTheEngine() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<100 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: Self.volume()))

        for _ in 0..<50 {
            let task = Task { try await handle.search(query: .everything).count() }
            task.cancel()
            _ = try? await task.value
        }
        let ready = await Self.waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 100 }
        #expect(ready, "the engine still works after many cancelled calls")
        try await handle.shutdown()
    }

    @Test func eventsReachEverySubscriberAndWorkerBatchesRoundTrip() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<12 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        let streamA = engine.events.stream()
        let streamB = engine.events.stream()
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: Self.volume()))

        func sawFoldersChanged(_ stream: AsyncStream<EngineEvent>) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            for await event in stream {
                if case .foldersChanged = event { return true }
                if ContinuousClock.now > deadline { break }
            }
            return false
        }
        async let a = sawFoldersChanged(streamA)
        async let b = sawFoldersChanged(streamB)
        #expect(await a)
        #expect(await b, "a second subscriber gets its own copy of every event")

        let ready = await Self.waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 12 }
        #expect(ready)

        // The two-call worker contract, driven from Swift with hand-made results.
        guard case .batch(let batch) = try await handle.nextMediaBatch(maxItems: 5) else {
            Issue.record("expected a batch")
            return
        }
        #expect(batch.tasks.count == 5)
        #expect(batch.tasks.allSatisfy { $0.thumbPath.hasSuffix("_1.jpg") && $0.path.hasPrefix("/") })
        #expect(handle.isBatchRevoked(batchId: batch.batchId) == false)
        var results: [MediaResultDto] = []
        for (index, task) in batch.tasks.enumerated() {
            if index == 0 {
                results.append(MediaResultDto(jobId: task.jobId, outcome: .failed(class: .fileCorrupt, message: "bad header")))
            } else {
                try Data("jpeg".utf8).write(to: URL(fileURLWithPath: task.thumbPath))
                var probe = ProbeDto(width: 4000, height: 3000, durationMs: nil, codec: nil, fps: nil, sampleRate: nil,
                                     channels: nil, bitrate: nil, captureAt: nil, cameraMake: "Sony", cameraModel: nil,
                                     lens: nil, gpsLat: nil, gpsLon: nil, exifJson: nil)
                probe.width = 4000
                results.append(MediaResultDto(jobId: task.jobId, outcome: .done(probe: probe, thumbWritten: true)))
            }
        }
        let report = try await handle.submitMediaResults(batchId: batch.batchId, results: results)
        #expect(report.committed == 4)
        #expect(report.failed == 1)
        let progress = await handle.progress()
        #expect(progress.mediaDone == 4)
        #expect(progress.mediaFailed == 1)
        #expect(progress.mediaRemaining == 7)
        // Submitting the same batch twice commits nothing the second time.
        let again = try await handle.submitMediaResults(batchId: batch.batchId, results: results)
        #expect(again.committed == 0)

        let committed = try await handle.summaries(assetIds: batch.tasks.dropFirst().map(\.assetId))
        #expect(committed.allSatisfy { $0.thumbRev == 1 && $0.width == 4000 && $0.aspect == .photo3x2 })
        try await handle.shutdown()
    }
}
