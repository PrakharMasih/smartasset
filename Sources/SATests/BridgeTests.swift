// Tests that cross the real Rust ↔ Swift boundary (plan §11: bridge tests).
import CoreBridge
import Foundation

func testVolume() -> MountedVolumeDto {
    MountedVolumeDto(uuid: "TEST-VOLUME", name: "Test Disk", mountPath: "/", isInternal: true)
}

let bridgeTests: [TestCase] = [
    TestCase(name: "bridge: open, add folder, page the results") {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<50 { try sandbox.write("clip\(index).mov", "video \(index)") }
        for index in 0..<25 { try sandbox.write("shots/IMG_\(index).jpg", "photo \(index)") }

        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let info = engine.handle.openInfo()
        try expectEqual(info.assetCount, 0)
        try expect(!info.uncleanExit)
        try await engine.handle.start()

        let outcome = try await engine.handle.addFolder(
            request: AddFolderRequestDto(path: sandbox.media.path, bookmark: Data([1, 2, 3]), volume: testVolume()))
        guard case .added(let folderId, let absorbed) = outcome else { throw fail("expected .added, got \(outcome)") }
        try expect(absorbed.isEmpty)

        let handle = engine.handle
        let reached = await waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 75 }
        try expect(reached, "the browse pass lists every file")

        let results = try await handle.search(query: .everything)
        try expectEqual(results.count(), 75)
        let firstPage = try await results.summaries(offset: 0, limit: 30)
        try expectEqual(firstPage.count, 30)
        try expectEqual(Set(firstPage.map(\.id)).count, 30, "no duplicates inside a page")
        let tailCount = try await results.summaries(offset: 70, limit: 100).count
        try expectEqual(tailCount, 5, "pages clamp to the end")
        let beyond = try await results.summaries(offset: 500, limit: 10)
        try expect(beyond.isEmpty)
        try expectEqual(results.idAt(index: 0), firstPage[0].id)
        try expectEqual(results.indexOf(id: firstPage[7].id), 7)

        let folders = try await handle.listFolders()
        try expectEqual(folders.count, 1)
        try expectEqual(folders[0].id, folderId)
        try expectEqual(folders[0].bookmark, Data([1, 2, 3]))
        try expect(folders[0].path != nil)

        var query = SearchQuery.everything
        query.text = "IMG_7"
        let hits = try await handle.search(query: query).count()
        try expectEqual(hits, 1)
        try await handle.shutdown()
    },

    TestCase(name: "bridge: Rust errors arrive as typed Swift errors") {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)

        do {
            try await engine.handle.removeFolder(folderId: 4242)
            throw fail("removing an unknown folder must throw")
        } catch let error as BridgeError {
            guard case .NotFound = error else { throw fail("wrong case: \(error)") }
            try expect(error.localizedDescription.contains("folder"), "message: \(error.localizedDescription)")
        }
        do {
            _ = try await engine.handle.addFolder(request: AddFolderRequestDto(
                path: sandbox.root.appending(path: "nope").path, bookmark: nil, volume: testVolume()))
            throw fail("adding a folder that does not exist must throw")
        } catch let error as BridgeError {
            guard case .Io = error else { throw fail("wrong case: \(error)") }
        }
        do {
            try await engine.handle.setRating(assetIds: [], rating: 9)
            throw fail("a rating of 9 must be rejected")
        } catch let error as BridgeError {
            guard case .Invalid = error else { throw fail("wrong case: \(error)") }
        }
        try await engine.handle.shutdown()
    },

    TestCase(name: "bridge: hundreds of concurrent calls are safe") {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<200 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: testVolume()))
        let ready = await waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 200 }
        try expect(ready)

        let ids = try await handle.search(query: .everything).allIds()
        let total = try await withThrowingTaskGroup(of: Int.self) { group in
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
            var sum = 0
            for try await value in group { sum += value }
            return sum
        }
        try expect(total > 0)
        var rated = SearchQuery.everything
        rated.filters.minRating = 1
        let ratedCount = try await handle.search(query: rated).count()
        try expect(ratedCount > 0)
        try await handle.shutdown()
    },

    TestCase(name: "bridge: cancelling tasks does not break the engine") {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<100 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: testVolume()))
        for _ in 0..<50 {
            let task = Task { try await handle.search(query: .everything).count() }
            task.cancel()
            _ = try? await task.value
        }
        let ready = await waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 100 }
        try expect(ready, "the engine still works after many cancelled calls")
        try await handle.shutdown()
    },

    TestCase(name: "bridge: events reach every subscriber; worker batch round-trips") {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        for index in 0..<12 { try sandbox.write("f\(index).jpg", "content \(index)") }
        let engine = try await CoreBridge.open(dataDirectory: sandbox.data, watch: false)
        let handle = engine.handle
        let streamA = engine.events.stream()
        let streamB = engine.events.stream()
        try await handle.start()
        _ = try await handle.addFolder(request: AddFolderRequestDto(path: sandbox.media.path, bookmark: nil, volume: testVolume()))

        @Sendable func sawFoldersChanged(_ stream: AsyncStream<EngineEvent>) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            for await event in stream {
                if case .foldersChanged = event { return true }
                if ContinuousClock.now > deadline { break }
            }
            return false
        }
        async let a = sawFoldersChanged(streamA)
        async let b = sawFoldersChanged(streamB)
        let (gotA, gotB) = await (a, b)
        try expect(gotA)
        try expect(gotB, "a second subscriber gets its own copy of every event")

        let ready = await waitUntil { ((try? await handle.search(query: .everything).count()) ?? 0) == 12 }
        try expect(ready)

        guard case .batch(let batch) = try await handle.nextMediaBatch(maxItems: 5) else { throw fail("expected a batch") }
        try expectEqual(batch.tasks.count, 5)
        try expect(batch.tasks.allSatisfy { $0.thumbPath.hasSuffix("_1.jpg") && $0.path.hasPrefix("/") })
        try expect(!handle.isBatchRevoked(batchId: batch.batchId))
        var results: [MediaResultDto] = []
        for (index, task) in batch.tasks.enumerated() {
            if index == 0 {
                results.append(MediaResultDto(jobId: task.jobId, outcome: .failed(class: .fileCorrupt, message: "bad header")))
            } else {
                try Data("jpeg".utf8).write(to: URL(fileURLWithPath: task.thumbPath))
                let probe = ProbeDto(width: 4000, height: 3000, durationMs: nil, codec: nil, fps: nil, sampleRate: nil,
                                     channels: nil, bitrate: nil, captureAt: nil, cameraMake: "Sony", cameraModel: nil,
                                     lens: nil, gpsLat: nil, gpsLon: nil, exifJson: nil)
                results.append(MediaResultDto(jobId: task.jobId, outcome: .done(probe: probe, thumbWritten: true)))
            }
        }
        let report = try await handle.submitMediaResults(batchId: batch.batchId, results: results)
        try expectEqual(report.committed, 4)
        try expectEqual(report.failed, 1)
        let progress = await handle.progress()
        try expectEqual(progress.mediaDone, 4)
        try expectEqual(progress.mediaFailed, 1)
        try expectEqual(progress.mediaRemaining, 7)
        let again = try await handle.submitMediaResults(batchId: batch.batchId, results: results)
        try expectEqual(again.committed, 0, "the same batch twice commits nothing the second time")

        let committed = try await handle.summaries(assetIds: batch.tasks.dropFirst().map(\.assetId))
        try expect(committed.allSatisfy { $0.thumbRev == 1 && $0.width == 4000 && $0.aspect == .standard4x3 })
        try await handle.shutdown()
    },
]

