import Foundation
import LumeRecorderKit
@testable import RecorderCore
import Testing

@Suite("RecordingScheduler")
struct SchedulerTests {
    let dir = makeTempDirectory()
    let streamURL = URL(string: "http://alice:s3cret@provider.example:8080/live/alice/s3cret/1234.ts")!

    private func makeScheduler(
        launcher: FakeLauncher = FakeLauncher(),
        options: RecordingScheduler.Options = fastOptions(),
        disk: FakeDisk = FakeDisk()
    ) throws -> (RecordingScheduler, RecorderStore) {
        let store = try RecorderStore(directory: dir)
        let scheduler = RecordingScheduler(store: store, launcher: launcher, options: options, disk: disk)
        return (scheduler, store)
    }

    private func request(start: TimeInterval, end: TimeInterval, title: String = "Show") -> CreateRecordingRequest {
        let now = Date()
        return CreateRecordingRequest(streamURL: streamURL, title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
    }

    private func status(_ store: RecorderStore, _ id: UUID) async -> RecordingStatus? {
        await store.recording(id)?.status
    }

    private func playlist(_ store: RecorderStore, _ id: UUID) -> String {
        (try? String(contentsOf: store.mediaDirectory(for: id).appendingPathComponent("index.m3u8"), encoding: .utf8)) ?? ""
    }

    @Test func scheduledThenRecordingThenCompleted() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher()
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, created) = try await scheduler.create(request(start: 0.4, end: 1.6), deviceID: nil, idempotencyKey: nil)
        #expect(created)
        #expect(record.status == .scheduled)
        #expect(launcher.processes.isEmpty)

        #expect(await eventually { await status(store, record.id) == .recording })
        #expect(await scheduler.activeCount == 1)
        #expect(await eventually { await status(store, record.id) == .completed })

        let final = try #require(await store.recording(record.id))
        #expect(final.attempts == 1)
        #expect(final.startedAt != nil && final.finishedAt != nil)
        #expect((final.durationSeconds ?? 0) > 0)
        #expect((final.sizeBytes ?? 0) > 0)
        #expect(final.failureReason == nil)
        #expect(playlist(store, record.id).hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(launcher.processes.first?.receivedSignals == ["INT"])
        let spec = try #require(launcher.specs.first)
        #expect(spec.attempt == 1)
        #expect(spec.maxDuration > 0.5 && spec.maxDuration <= 1.25)
        #expect(await scheduler.activeCount == 0)
    }

    @Test func stoppingAScheduledRecordingCancelsIt() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher()
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0.5, end: 5), deviceID: nil, idempotencyKey: nil)
        let stopped = try await scheduler.stop(record.id)
        #expect(stopped.status == .cancelled)
        try await Task.sleep(for: .seconds(0.8))
        #expect(await status(store, record.id) == .cancelled)
        #expect(launcher.processes.isEmpty)
    }

    @Test func stoppingAnActiveRecordingCompletesIt() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher()
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: -5, end: 60), deviceID: nil, idempotencyKey: nil)
        #expect(record.status == .recording)
        try await Task.sleep(for: .seconds(0.4))
        let stopped = try await scheduler.stop(record.id)
        #expect(stopped.status == .completed)
        #expect(stopped.finishedAt != nil)
        #expect(launcher.processes.first?.receivedSignals == ["INT"])
        #expect(playlist(store, record.id).contains("#EXT-X-ENDLIST"))
        // Stopping again is a harmless no-op.
        #expect(try await scheduler.stop(record.id).status == .completed)
    }

    @Test func deletingAnActiveRecordingStopsItAndRemovesMedia() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, store) = try makeScheduler()
        let (record, _) = try await scheduler.create(request(start: 0, end: 60), deviceID: nil, idempotencyKey: nil)
        let media = store.mediaDirectory(for: record.id)
        #expect(await eventually { FileManager.default.fileExists(atPath: media.appendingPathComponent("index.m3u8").path) })
        try await scheduler.delete(record.id)
        #expect(await store.recording(record.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: media.path))
        await #expect(throws: RecorderError.notFound) { try await scheduler.delete(record.id) }
    }

    @Test func earlyExitIsRetriedWithANewAttemptAndDiscontinuity() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher([
            .exitAfter(0.2, segments: 2, status: 1, stderr: "Connection reset by peer"),
            .runUntilSignalled(),
        ])
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0, end: 1.5), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .completed })

        let final = try #require(await store.recording(record.id))
        #expect(final.attempts == 2)
        #expect(launcher.specs.map(\.attempt) == [1, 2])
        let text = playlist(store, record.id)
        #expect(text.contains("a1_00000.ts") && text.contains("a2_"))
        #expect(text.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1 == 2)
        #expect(text.components(separatedBy: "#EXT-X-ENDLIST").count - 1 == 1)
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func zeroSegmentsFailsWithARedactedReason() async throws {
        defer { removeTempDirectory(dir) }
        let stderr = "[http @ 0x1] HTTP error 404 Not Found\nError opening input file \(streamURL.absoluteString).\nError opening input files: Server returned 404 Not Found\n"
        let launcher = FakeLauncher([.exitAfter(0.05, segments: 0, status: 1, stderr: stderr)])
        var options = fastOptions()
        options.sourceUnavailableAfterQuickExits = 0 // retry for the whole window
        let (scheduler, store) = try makeScheduler(launcher: launcher, options: options)
        let (record, _) = try await scheduler.create(request(start: 0, end: 0.9), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .failed })

        let reason = try #require(await store.recording(record.id)?.failureReason)
        #expect(reason.hasPrefix("no_segments"))
        #expect(reason.contains("404"))
        #expect(!reason.contains("s3cret"))
        #expect(!reason.contains("alice"))
        #expect(!reason.contains("provider.example"))
        #expect(!reason.contains("http://"))
        #expect(launcher.processes.count >= 2) // it kept retrying until the end
    }

    @Test func repeatedImmediateExitsFailAsSourceUnavailable() async throws {
        defer { removeTempDirectory(dir) }
        let stderr = "[hls @ 0x1] Opening '\(streamURL.absoluteString)' for reading\n[hls @ 0x1] Error when loading first segment '\(streamURL.absoluteString)'\nError opening input files: Invalid data found when processing input\n"
        let launcher = FakeLauncher([.exitAfter(0.01, segments: 0, status: 183, stderr: stderr)])
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0, end: 60), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .failed })

        let final = try #require(await store.recording(record.id))
        let reason = try #require(final.failureReason)
        #expect(reason.hasPrefix("source_unavailable: "))
        #expect(reason.contains("Error when loading first segment"))
        for secret in ["s3cret", "alice", "provider.example", "http://"] {
            #expect(!reason.contains(secret), "leaked \(secret)")
        }
        #expect(launcher.processes.count == 5)
        #expect(final.attempts == 5)
        #expect(final.finishedAt != nil)
        #expect(await scheduler.activeCount == 0)
    }

    @Test func immediateExitsAfterCapturedMediaKeepRetrying() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher([
            .exitAfter(0.05, segments: 2, status: 1, stderr: "Connection reset by peer"),
            .exitAfter(0.01, segments: 0, status: 1, stderr: "Connection refused"),
        ])
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0, end: 2.5), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .completed })
        #expect(launcher.processes.count > 6)
        #expect(await store.recording(record.id)?.failureReason == nil)
    }

    @Test func hlsExtensionMismatchTurnsOnTheRelaxedCheck() async throws {
        defer { removeTempDirectory(dir) }
        let mismatch = "[hls @ 0x1] detected format webvtt extension vtt mismatches allowed extensions in url https://cdn.example/sub.mp4\n[hls @ 0x1] Error when loading first segment\n"
        let launcher = FakeLauncher([
            .exitAfter(0.01, segments: 0, status: 183, stderr: mismatch),
            .exitAfter(0.01, segments: 0, status: 8, stderr: "Option extension_picky not found.\n"),
            .runUntilSignalled(),
        ])
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0, end: 1.2), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .completed })
        // `.ts` URL: off at first, on after the mismatch, off again once ffmpeg refuses it.
        #expect(launcher.specs.prefix(3).map(\.hlsInput) == [false, true, false])
    }

    @Test func endingEscalatesToSIGTERMWhenSIGINTIsIgnored() async throws {
        defer { removeTempDirectory(dir) }
        let launcher = FakeLauncher([.ignoreInterrupt()])
        let (scheduler, store) = try makeScheduler(launcher: launcher)
        let (record, _) = try await scheduler.create(request(start: 0, end: 0.6), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, record.id) == .completed })
        #expect(launcher.processes.first?.receivedSignals == ["INT", "TERM"])
        // ffmpeg never wrote ENDLIST, the scheduler appended it.
        #expect(playlist(store, record.id).hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func immediateStartOverTheConcurrencyCapIsRejected() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, store) = try makeScheduler(options: fastOptions(maxConcurrent: 1))
        let (first, _) = try await scheduler.create(request(start: 0, end: 30), deviceID: nil, idempotencyKey: nil)
        await #expect(throws: RecorderError.concurrencyLimit) {
            _ = try await scheduler.create(request(start: 0, end: 30), deviceID: nil, idempotencyKey: nil)
        }
        #expect(await store.recordings().count == 1)
        _ = try await scheduler.stop(first.id)
    }

    @Test func scheduledStartOverTheConcurrencyCapFails() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, store) = try makeScheduler(options: fastOptions(maxConcurrent: 1))
        let (first, _) = try await scheduler.create(request(start: 0, end: 30), deviceID: nil, idempotencyKey: nil)
        let (second, _) = try await scheduler.create(request(start: 0.3, end: 30), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, second.id) == .failed })
        #expect(await store.recording(second.id)?.failureReason == "concurrency_limit")
        _ = try await scheduler.stop(first.id)
    }

    @Test func lowDiskRejectsImmediateAndFailsScheduled() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, store) = try makeScheduler(options: fastOptions(minFreeBytes: 2_000_000_000), disk: FakeDisk(freeBytes: 1_000))
        await #expect(throws: RecorderError.insufficientStorage) {
            _ = try await scheduler.create(request(start: 0, end: 30), deviceID: nil, idempotencyKey: nil)
        }
        let (later, _) = try await scheduler.create(request(start: 0.2, end: 30), deviceID: nil, idempotencyKey: nil)
        #expect(await eventually { await status(store, later.id) == .failed })
        #expect(await store.recording(later.id)?.failureReason == "insufficient_storage")
    }

    @Test(arguments: [
        ("ftp://provider.example/1.ts", 10.0, 20.0, "streamURL"),
        ("http://provider.example/1.ts", 20.0, 10.0, "end must be after start"),
        ("http://provider.example/1.ts", -20.0, -10.0, "end must be in the future"),
        ("http://provider.example/1.ts", 0.0, 13 * 3600.0, "at most 12 hours"),
    ])
    func invalidRequestsAreRejected(url: String, start: TimeInterval, end: TimeInterval, message: String) async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, _) = try makeScheduler()
        let now = Date()
        let request = CreateRecordingRequest(streamURL: URL(string: url)!, title: "x", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
        do {
            _ = try await scheduler.create(request, deviceID: nil, idempotencyKey: nil)
            Issue.record("expected a validation error")
        } catch let RecorderError.invalidRequest(text) {
            #expect(text.contains(message))
        }
    }

    @Test func emptyTitleIsRejected() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, _) = try makeScheduler()
        await #expect(throws: RecorderError.invalidRequest("title must not be empty")) {
            _ = try await scheduler.create(request(start: 10, end: 20, title: "  "), deviceID: nil, idempotencyKey: nil)
        }
    }

    @Test func idempotencyKeyIsScopedPerDevice() async throws {
        defer { removeTempDirectory(dir) }
        let (scheduler, store) = try makeScheduler()
        let device = UUID()
        let (first, created) = try await scheduler.create(request(start: 60, end: 120), deviceID: device, idempotencyKey: "abc")
        let (again, createdAgain) = try await scheduler.create(request(start: 60, end: 120), deviceID: device, idempotencyKey: "abc")
        let (other, createdOther) = try await scheduler.create(request(start: 60, end: 120), deviceID: UUID(), idempotencyKey: "abc")
        #expect(created && !createdAgain && createdOther)
        #expect(first.id == again.id)
        #expect(other.id != first.id)
        #expect(await store.recordings().count == 2)
    }
}

@Suite("Restart recovery")
struct RecoveryTests {
    let dir = makeTempDirectory()
    let streamURL = URL(string: "http://provider.example/live/u/p/1.ts")!

    private func insert(_ store: RecorderStore, status: RecordingStatus, start: TimeInterval, end: TimeInterval, attempts: Int = 0, segments: Bool = false) async throws -> UUID {
        let now = Date()
        let record = RecordingRecord(streamURL: streamURL, title: "\(status)", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), status: status, createdAt: now, startedAt: status == .recording ? now.addingTimeInterval(start) : nil, attempts: attempts)
        try await store.insert(record)
        if segments {
            let media = store.mediaDirectory(for: record.id)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:6.0,\na1_00000.ts\n".write(to: media.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: media.appendingPathComponent("a1_00000.ts").path, contents: Data(count: 1880))
        }
        return record.id
    }

    @Test func reconcilesEveryPersistedState() async throws {
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        let resumable = try await insert(store, status: .recording, start: -60, end: 60, attempts: 3, segments: true)
        let finishedWithMedia = try await insert(store, status: .recording, start: -120, end: -60, attempts: 1, segments: true)
        let finishedEmpty = try await insert(store, status: .recording, start: -120, end: -60, attempts: 1)
        let missed = try await insert(store, status: .scheduled, start: -120, end: -60)
        let lateStart = try await insert(store, status: .scheduled, start: -10, end: 60)
        let future = try await insert(store, status: .scheduled, start: 3600, end: 7200)
        let done = try await insert(store, status: .completed, start: -500, end: -400)

        // Simulate a restart: a brand-new store + scheduler over the same directory.
        let launcher = FakeLauncher()
        let reopened = try RecorderStore(directory: dir)
        let scheduler = RecordingScheduler(store: reopened, launcher: launcher, options: fastOptions(), disk: FakeDisk())
        await scheduler.recover()

        #expect(await reopened.recording(finishedWithMedia)?.status == .completed)
        let completedPlaylist = try String(contentsOf: reopened.mediaDirectory(for: finishedWithMedia).appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(completedPlaylist.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(await reopened.recording(finishedEmpty)?.status == .failed)
        #expect(await reopened.recording(finishedEmpty)?.failureReason == "interrupted")
        #expect(await reopened.recording(missed)?.status == .failed)
        #expect(await reopened.recording(missed)?.failureReason == "missed")
        #expect(await reopened.recording(future)?.status == .scheduled)
        #expect(await reopened.recording(done)?.status == .completed)

        // The interrupted live recording resumes as attempt 4; the late scheduled one starts now.
        #expect(await eventually { launcher.specs.count == 2 })
        let attempts = Dictionary(uniqueKeysWithValues: launcher.specs.map { ($0.recordingID, $0.attempt) })
        #expect(attempts[resumable] == 4)
        #expect(attempts[lateStart] == 1)
        #expect(await reopened.recording(resumable)?.status == .recording)
        #expect(await reopened.recording(lateStart)?.status == .recording)
        await scheduler.shutdown()
    }

    @Test func shutdownKeepsRowsRecordingForTheNextStart() async throws {
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        let launcher = FakeLauncher()
        let scheduler = RecordingScheduler(store: store, launcher: launcher, options: fastOptions(), disk: FakeDisk())
        let now = Date()
        let (record, _) = try await scheduler.create(
            CreateRecordingRequest(streamURL: streamURL, title: "Live", start: now, end: now.addingTimeInterval(60)),
            deviceID: nil, idempotencyKey: nil
        )
        try await Task.sleep(for: .seconds(0.3))
        await scheduler.shutdown()
        #expect(launcher.processes.first?.receivedSignals == ["INT"])
        #expect(await store.recording(record.id)?.status == .recording)

        let relaunched = FakeLauncher()
        let next = RecordingScheduler(store: try RecorderStore(directory: dir), launcher: relaunched, options: fastOptions(), disk: FakeDisk())
        await next.recover()
        #expect(await eventually { relaunched.specs.first?.attempt == 2 })
        await next.shutdown()
    }
}
