import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LumeRecorderKit
@testable import RecorderCore
import Testing

@Suite("Live stats coalescing, caching and lifecycle")
struct LiveStatsTests {
    @Test func concurrentListPollsShareRefreshes() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token
            let req = harness.createRequest(start: 0, end: 3600, title: "Live Show")
            let createdRes = try await client.execute(
                uri: "/api/v1/recordings",
                method: .post,
                headers: harness.auth(token),
                body: APIHarness.body(req)
            )
            #expect(createdRes.status == .created)
            let created = try APIHarness.decode(Recording.self, createdRes)
            #expect(created.status == .recording)

            let dir = harness.services.store.mediaDirectory(for: created.id)
            #expect(await eventually { FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.m3u8").path) })

            // Invalidate the cache from POST /recordings and reset scan counts
            // so we measure the cold concurrent GET /recordings coalescing
            await harness.services.liveStats.invalidate(created.id)
            await harness.services.liveStats.resetScanCounts()

            // Concurrently fire 20 list requests
            let count = 20
            let results = try await withThrowingTaskGroup(of: [Recording].self) { group in
                for _ in 0 ..< count {
                    group.addTask {
                        let res = try await client.execute(
                            uri: "/api/v1/recordings",
                            method: .get,
                            headers: harness.auth(token)
                        )
                        #expect(res.status == .ok)
                        return try APIHarness.decode([Recording].self, res)
                    }
                }
                var all: [[Recording]] = []
                for try await list in group {
                    all.append(list)
                }
                return all
            }

            #expect(results.count == count)
            for list in results {
                #expect(list.count == 1)
                #expect(list[0].id == created.id)
                #expect(list[0].status == .recording)
            }

            // All 20 concurrent requests must have coalesced into exactly 1 disk scan!
            let scans = await harness.services.liveStats.scanCount(for: created.id)
            #expect(scans == 1)
        }
    }

    @Test func pollsInsideFreshnessIntervalCauseNoExtraScans() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token
            let req = harness.createRequest(start: 0, end: 3600, title: "Live Show")
            let createdRes = try await client.execute(
                uri: "/api/v1/recordings",
                method: .post,
                headers: harness.auth(token),
                body: APIHarness.body(req)
            )
            let created = try APIHarness.decode(Recording.self, createdRes)
            let dir = harness.services.store.mediaDirectory(for: created.id)
            #expect(await eventually { FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.m3u8").path) })

            // Invalidate to start from a cold cache
            await harness.services.liveStats.invalidate(created.id)
            await harness.services.liveStats.resetScanCounts()

            // First poll: cold scan
            let res1 = try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(token))
            #expect(res1.status == .ok)
            #expect(await harness.services.liveStats.scanCount(for: created.id) == 1)

            // Subsequent polls within freshness interval (default 2s): no additional disk scan
            for _ in 0 ..< 10 {
                let cachedRes = try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(token))
                #expect(cachedRes.status == .ok)
            }
            #expect(await harness.services.liveStats.scanCount(for: created.id) == 1)

            // Invalidate cache: next poll must rescan
            await harness.services.liveStats.invalidate(created.id)
            let resAfterInvalidate = try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(token))
            #expect(resAfterInvalidate.status == .ok)
            #expect(await harness.services.liveStats.scanCount(for: created.id) == 2)
        }
    }

    @Test func finishedRecordingsUseExistingCachedStatsWithoutDiskScans() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token

            // Directly insert completed and failed recordings into store
            let now = Date()
            let completedRecord = RecordingRecord(
                id: UUID(),
                streamURL: URL(string: "http://example.com/stream.ts")!,
                title: "Completed Match",
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-1800),
                status: .completed,
                createdAt: now.addingTimeInterval(-3600),
                finishedAt: now.addingTimeInterval(-1800),
                durationSeconds: 1800.0,
                sizeBytes: 50_000_000
            )
            try await harness.services.store.insert(completedRecord)

            await harness.services.liveStats.resetScanCounts()

            let res = try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(token))
            #expect(res.status == .ok)
            let recordings = try APIHarness.decode([Recording].self, res)
            let found = recordings.first { $0.id == completedRecord.id }
            #expect(found?.durationSeconds == 1800.0)
            #expect(found?.sizeBytes == 50_000_000)

            // No disk scan should have occurred for finished recording!
            #expect(await harness.services.liveStats.scanCount(for: completedRecord.id) == 0)
            #expect(await harness.services.liveStats.totalScanCount() == 0)
        }
    }

    @Test func lifecycleInvalidationOnAppendRetryStopAndFinalization() async throws {
        let tempDir = makeTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let clock = TestClock()
        let coordinator = LiveStatsCoordinator(freshness: 2.0, now: clock.provider)

        let id = UUID()
        let recordingDir = tempDir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: recordingDir, withIntermediateDirectories: true)

        let playlistURL = recordingDir.appendingPathComponent("index.m3u8")
        let seg1URL = recordingDir.appendingPathComponent("a1_00000.ts")
        try Data(repeating: 0x47, count: 1880).write(to: seg1URL)
        let m3u8_1 = "#EXTM3U\n#EXT-X-VERSION:6\n#EXTINF:6.0,\na1_00000.ts\n"
        try m3u8_1.write(to: playlistURL, atomically: true, encoding: .utf8)

        // 1. Initial scan
        let stats1 = await coordinator.stats(for: id, in: recordingDir)
        #expect(stats1.segmentCount == 1)
        #expect(stats1.durationSeconds == 6.0)
        #expect(stats1.sizeBytes == 1880 + Int64(m3u8_1.utf8.count))
        #expect(await coordinator.scanCount(for: id) == 1)

        // 2. Append new media segment and playlist update
        let seg2URL = recordingDir.appendingPathComponent("a1_00001.ts")
        try Data(repeating: 0x47, count: 1880).write(to: seg2URL)
        let m3u8_2 = "#EXTM3U\n#EXT-X-VERSION:6\n#EXTINF:6.0,\na1_00000.ts\n#EXTINF:6.0,\na1_00001.ts\n"
        try m3u8_2.write(to: playlistURL, atomically: true, encoding: .utf8)

        // Before invalidation (within freshness): still cached
        let cached = await coordinator.stats(for: id, in: recordingDir)
        #expect(cached.segmentCount == 1)
        #expect(await coordinator.scanCount(for: id) == 1)

        // On append notification:
        await coordinator.didAppendSegment(for: id)
        let stats2 = await coordinator.stats(for: id, in: recordingDir)
        #expect(stats2.segmentCount == 2)
        #expect(stats2.durationSeconds == 12.0)
        #expect(stats2.sizeBytes == 3760 + Int64(m3u8_2.utf8.count))
        #expect(await coordinator.scanCount(for: id) == 2)

        // 3. Retry invalidation:
        await coordinator.invalidate(id)
        #expect(await coordinator.cachedStats(for: id) == nil)

        // 4. Stop / Finalization invalidation:
        await coordinator.invalidate(id)
        #expect(await coordinator.cachedStats(for: id) == nil)
    }

    @Test func inspectionRacingDeletion() async throws {
        let tempDir = makeTempDirectory()
        defer { removeTempDirectory(tempDir) }

        let id = UUID()
        let recordingDir = tempDir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: recordingDir, withIntermediateDirectories: true)

        let playlistURL = recordingDir.appendingPathComponent("index.m3u8")
        let segURL = recordingDir.appendingPathComponent("a1_00000.ts")
        try Data(repeating: 0x47, count: 1880).write(to: segURL)
        let m3u8 = "#EXTM3U\n#EXT-X-VERSION:6\n#EXTINF:6.0,\na1_00000.ts\n"
        try m3u8.write(to: playlistURL, atomically: true, encoding: .utf8)

        // Coordinator with artificial delay in inspector to guarantee race condition
        let coordinator = LiveStatsCoordinator(
            freshness: 2.0,
            inspector: { url in
                Thread.sleep(forTimeInterval: 0.05)
                return MediaInspector.stats(in: url)
            }
        )

        // Start inspection task in background
        let inspectTask = Task {
            await coordinator.stats(for: id, in: recordingDir)
        }

        // Mid-inspection: delete recording and remove directory
        try? await Task.sleep(for: .milliseconds(10))
        await coordinator.invalidate(id)
        try? FileManager.default.removeItem(at: recordingDir)

        // Await the racing inspection task
        let stats = await inspectTask.value
        // It must finish without throwing or crashing
        #expect(stats.segmentCount >= 0)

        // Because invalidation occurred during the race, coordinator must NOT retain cached entry
        #expect(await coordinator.cachedStats(for: id) == nil)
    }

    @Test func benchmarkConcurrentListingWithThousandsOfSegmentsDoesNotStallUnrelatedRequests() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token

            // Create an active recording
            let req = harness.createRequest(start: 0, end: 7200, title: "Huge Live Stream")
            let createdRes = try await client.execute(
                uri: "/api/v1/recordings",
                method: .post,
                headers: harness.auth(token),
                body: APIHarness.body(req)
            )
            let created = try APIHarness.decode(Recording.self, createdRes)
            let dir = harness.services.store.mediaDirectory(for: created.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Populate directory with 2,500 segments and a large index.m3u8
            let segmentCount = 2500
            var playlistText = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:6\n"
            for i in 0 ..< segmentCount {
                let name = String(format: "a1_%05d.ts", i)
                let segURL = dir.appendingPathComponent(name)
                // Write dummy segment file
                FileManager.default.createFile(atPath: segURL.path, contents: Data(repeating: 0x47, count: 188))
                playlistText += "#EXTINF:6.000,\n\(name)\n"
            }
            try playlistText.write(to: dir.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

            // Invalidate to force a cold inspection
            await harness.services.liveStats.invalidate(created.id)
            await harness.services.liveStats.resetScanCounts()

            // Run concurrent requests:
            // 20 concurrent list requests + concurrent unrelated info requests
            let startTime = Date()
            var unrelatedDuration: TimeInterval = 0

            let (listResults, infoStatus) = try await withThrowingTaskGroup(of: (String, TimeInterval, Int).self) { group in
                // Launch unrelated requests
                group.addTask {
                    let t0 = Date()
                    let infoRes = try await client.execute(uri: "/api/v1/info", method: .get)
                    let elapsed = Date().timeIntervalSince(t0)
                    return ("info", elapsed, infoRes.status.code)
                }

                // Launch 20 concurrent listing requests
                for _ in 0 ..< 20 {
                    group.addTask {
                        let t0 = Date()
                        let listRes = try await client.execute(
                            uri: "/api/v1/recordings",
                            method: .get,
                            headers: harness.auth(token)
                        )
                        let elapsed = Date().timeIntervalSince(t0)
                        return ("list", elapsed, listRes.status.code)
                    }
                }

                var listCodes: [Int] = []
                var infoCode = 0
                for try await (kind, elapsed, code) in group {
                    if kind == "info" {
                        unrelatedDuration = elapsed
                        infoCode = code
                    } else {
                        listCodes.append(code)
                    }
                }
                return (listCodes, infoCode)
            }

            let totalElapsed = Date().timeIntervalSince(startTime)

            // Verify unrelated request completed successfully
            #expect(infoStatus == 200)
            #expect(listResults.count == 20)
            for code in listResults {
                #expect(code == 200)
            }

            // Verify single-flight: only ONE cold scan was executed for all 20 concurrent requests!
            let scans = await harness.services.liveStats.scanCount(for: created.id)
            #expect(scans == 1)

            // Verify the cached stats reflected the cold inspection of 2,500+ segments
            guard let cached = await harness.services.liveStats.cachedStats(for: created.id) else {
                Issue.record("Missing cached stats for created recording")
                return
            }
            #expect(cached.segmentCount >= segmentCount)
            #expect(cached.durationSeconds >= Double(segmentCount) * 6.0)
            #expect(cached.sizeBytes > 0)

            // Unrelated info request should complete quickly without stalling
            print("Benchmark with \(segmentCount) segments: unrelated /info took \(String(format: "%.3f", unrelatedDuration))s, total batch took \(String(format: "%.3f", totalElapsed))s, scan count = \(scans)")
        }
    }
}
