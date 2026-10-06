import Foundation
import Hummingbird
import HummingbirdTesting
import LumeRecorderKit
@testable import RecorderCore
import Testing

/// Finds a usable ffmpeg (FFMPEG_PATH, PATH, Homebrew), or nil to skip.
enum TestFFmpeg {
    static let path: String? = {
        if let configured = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           FFmpegArguments.resolveExecutable(configured) != nil {
            return configured
        }
        if let onPath = FFmpegArguments.resolveExecutable("ffmpeg") { return onPath.path }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }()
}

@Suite("Real ffmpeg", .enabled(if: TestFFmpeg.path != nil, "ffmpeg not installed"))
struct FFmpegIntegrationTests {
    /// Generates a 20 s MPEG-TS test pattern with lavfi.
    private func makeSource(in dir: URL, ffmpeg: String) throws -> URL {
        let output = dir.appendingPathComponent("source.ts")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "20", "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac",
            "-f", "mpegts", output.path,
        ]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // No libx264 (some Linux builds): fall back to mpeg2video.
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: ffmpeg)
            fallback.arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-t", "20", "-c:v", "mpeg2video", "-g", "25", "-c:a", "mp2",
                "-f", "mpegts", output.path,
            ]
            fallback.standardInput = FileHandle.nullDevice
            try fallback.run()
            fallback.waitUntilExit()
            try #require(fallback.terminationStatus == 0, "couldn't generate a test source")
            return output
        }
        return output
    }

    @Test(.timeLimit(.minutes(2)))
    func recordsALocalHTTPStreamToHLS() async throws {
        let ffmpeg = try #require(TestFFmpeg.path)
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let source = try makeSource(in: dir, ffmpeg: ffmpeg)
        let sourceBytes = try Data(contentsOf: source)

        // A tiny local HTTP origin serving the TS like an IPTV provider.
        let originRouter = Router()
        originRouter.get("live/user/pass/1.ts") { _, _ in
            Response(status: .ok, headers: [.contentType: "video/mp2t"], body: .init(byteBuffer: ByteBuffer(bytes: sourceBytes)))
        }
        let origin = Application(router: originRouter, configuration: .init(address: .hostname("127.0.0.1", port: 0)))

        try await origin.test(.live) { client in
            let port = try #require(client.port)
            // The live test framework binds "localhost" (may be ::1 only).
            let streamURL = URL(string: "http://localhost:\(port)/live/user/pass/1.ts")!
            let store = try RecorderStore(directory: dir.appendingPathComponent("data"))
            // Real-time pacing without the initial burst, so the recording runs
            // for its whole window and ends via SIGINT like a live source.
            var capabilities = FFmpegCapabilities.detect(executable: URL(fileURLWithPath: ffmpeg))
            capabilities.readRateInitialBurst = false
            let launcher = FFmpegLauncher(path: ffmpeg, capabilities: capabilities)
            let scheduler = RecordingScheduler(store: store, launcher: launcher, options: fastOptions(), disk: FakeDisk())

            let now = Date()
            let (record, _) = try await scheduler.create(
                CreateRecordingRequest(streamURL: streamURL, title: "Integration", start: now, end: now.addingTimeInterval(4)),
                deviceID: nil, idempotencyKey: nil
            )
            #expect(await eventually(timeout: 60) { await store.recording(record.id)?.status.isPending == false })

            let final = try #require(await store.recording(record.id))
            #expect(final.status == .completed, "failure: \(final.failureReason ?? "-")")
            let playlist = try String(contentsOf: store.mediaDirectory(for: record.id).appendingPathComponent("index.m3u8"), encoding: .utf8)
            let summary = HLSPlaylist.summarize(playlist)
            #expect(summary.segmentCount >= 1)
            #expect(summary.hasEndList)
            #expect(playlist.contains("a1_00000.ts"))
            #expect(summary.durationSeconds > 2.5 && summary.durationSeconds < 6, "duration \(summary.durationSeconds)")
            let wallClock = try #require(final.finishedAt).timeIntervalSince(now)
            #expect(wallClock > 3.5, "finished after \(wallClock) s — not paced in real time")
            #expect((final.sizeBytes ?? 0) > 10_000)
        }
    }

    /// ffmpeg has to honour SIGINT: a child inherits its spawning thread's
    /// signal mask, and on Linux the executor's threads block SIGINT/SIGTERM.
    @Test(.timeLimit(.minutes(2)))
    func aRequestedStopEndsFFmpegOnSIGINT() async throws {
        let ffmpeg = try #require(TestFFmpeg.path)
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let sourceBytes = try Data(contentsOf: makeSource(in: dir, ffmpeg: ffmpeg))

        let originRouter = Router()
        originRouter.get("live/user/pass/1.ts") { _, _ in
            Response(status: .ok, headers: [.contentType: "video/mp2t"], body: .init(byteBuffer: ByteBuffer(bytes: sourceBytes)))
        }
        let origin = Application(router: originRouter, configuration: .init(address: .hostname("127.0.0.1", port: 0)))

        try await origin.test(.live) { client in
            let port = try #require(client.port)
            let streamURL = URL(string: "http://localhost:\(port)/live/user/pass/1.ts")!
            let store = try RecorderStore(directory: dir.appendingPathComponent("data"))
            var capabilities = FFmpegCapabilities.detect(executable: URL(fileURLWithPath: ffmpeg))
            capabilities.readRateInitialBurst = false
            var options = fastOptions()
            // Ignoring SIGINT would cost the full 5 s, and SIGTERM 5 s more.
            options.requestedStopGracePeriod = 5
            options.terminateGracePeriod = 5
            let scheduler = RecordingScheduler(
                store: store, launcher: FFmpegLauncher(path: ffmpeg, capabilities: capabilities),
                options: options, disk: FakeDisk()
            )

            let now = Date()
            let (record, _) = try await scheduler.create(
                CreateRecordingRequest(streamURL: streamURL, title: "Stop", start: now, end: now.addingTimeInterval(60)),
                deviceID: nil, idempotencyKey: nil
            )
            let media = store.mediaDirectory(for: record.id)
            #expect(await eventually(timeout: 30) { MediaInspector.stats(in: media).segmentCount > 0 })

            let clock = ContinuousClock()
            let started = clock.now
            let stopped = try await scheduler.stop(record.id)
            let elapsed = clock.now - started

            #expect(elapsed < .seconds(3), "stop took \(elapsed)")
            #expect(stopped.status == .completed, "failure: \(stopped.failureReason ?? "-")")
        }
    }
}
