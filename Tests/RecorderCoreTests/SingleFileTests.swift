import Foundation
import LumeRecorderKit
@testable import RecorderCore
import Testing

@Suite("Single-file recordings")
struct SingleFileTests {
    let dir = makeTempDirectory()
    let streamURL = URL(string: "http://provider.example/live/u/p/1.ts")!

    private func playlist(in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("index.m3u8"), encoding: .utf8)
    }

    /// Two attempts' worth of segments with distinct bytes, like ffmpeg's append_list.
    private func writeSegmentedRecording(in directory: URL) throws -> [Data] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["a1_00000.ts", "a1_00001.ts", "a2_00000.ts"]
        let contents = names.enumerated().map { index, _ in Data(repeating: UInt8(index + 1), count: 188 * (index + 2)) }
        for (name, data) in zip(names, contents) {
            try data.write(to: directory.appendingPathComponent(name))
        }
        try """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXTINF:6.000000,
        a1_00000.ts
        #EXTINF:4.000000,
        a1_00001.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.500000,
        a2_00000.ts
        #EXT-X-ENDLIST

        """.write(to: directory.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        return contents
    }

    @Test func mergesSegmentsIntoOneByteRangeFile() throws {
        defer { removeTempDirectory(dir) }
        let contents = try writeSegmentedRecording(in: dir)

        #expect(try SingleFileRecording.consolidate(in: dir))

        let merged = try Data(contentsOf: dir.appendingPathComponent("recording.ts"))
        #expect(merged == contents.reduce(Data(), +))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["index.m3u8", "recording.ts"])

        let text = try playlist(in: dir)
        #expect(text.contains("#EXT-X-VERSION:4\n"))
        #expect(text.contains("#EXTINF:6.000000,\n#EXT-X-BYTERANGE:376@0\nrecording.ts\n"))
        #expect(text.contains("#EXTINF:4.000000,\n#EXT-X-BYTERANGE:564@376\nrecording.ts\n"))
        #expect(text.contains("#EXT-X-DISCONTINUITY\n#EXTINF:5.500000,\n#EXT-X-BYTERANGE:752@940\nrecording.ts\n"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(!text.contains("a1_"))
        #expect(SingleFileRecording.isConsolidated(in: dir))

        let stats = MediaInspector.stats(in: dir)
        #expect(stats.segmentCount == 3)
        #expect(stats.durationSeconds == 15.5)
        #expect(stats.sizeBytes == Int64(merged.count) + Int64(Data(text.utf8).count))
    }

    @Test func mergingAgainIsANoOpThatCleansUpACrash() throws {
        defer { removeTempDirectory(dir) }
        _ = try writeSegmentedRecording(in: dir)
        try SingleFileRecording.consolidate(in: dir)
        let merged = try Data(contentsOf: dir.appendingPathComponent("recording.ts"))

        // A crash after the playlist swap leaves segments and a partial behind.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a1_00000.ts").path, contents: Data(count: 188))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("recording.partial").path, contents: Data(count: 188))

        #expect(try SingleFileRecording.consolidate(in: dir) == false)
        #expect(try Data(contentsOf: dir.appendingPathComponent("recording.ts")) == merged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["index.m3u8", "recording.ts"])
    }

    @Test func aMissingSegmentLeavesTheRecordingSegmented() throws {
        defer { removeTempDirectory(dir) }
        _ = try writeSegmentedRecording(in: dir)
        let before = try playlist(in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a1_00001.ts"))

        #expect(throws: (any Error).self) { try SingleFileRecording.consolidate(in: dir) }
        #expect(try playlist(in: dir) == before)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.ts").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.partial").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a1_00000.ts").path))
    }

    @Test func aPlaylistWithoutAVersionGetsOne() {
        let text = SingleFileRecording.rewrite("#EXTM3U\n#EXTINF:6.0,\na1_00000.ts\n", ranges: [(length: 10, offset: 0)])
        #expect(text == "#EXTM3U\n#EXT-X-VERSION:4\n#EXTINF:6.0,\n#EXT-X-BYTERANGE:10@0\nrecording.ts\n")
    }

    @Test func schedulerMergesAFinishedRecording() async throws {
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        var options = fastOptions()
        options.singleFileRecordings = true
        let launcher = FakeLauncher([.exitAfter(0.3, segments: 2, status: 0), .runUntilSignalled()])
        let scheduler = RecordingScheduler(store: store, launcher: launcher, options: options, disk: FakeDisk())
        let now = Date()
        let (record, _) = try await scheduler.create(
            CreateRecordingRequest(streamURL: streamURL, title: "Single", start: now, end: now.addingTimeInterval(1.5)),
            deviceID: nil, idempotencyKey: nil
        )
        // Live: plain segments while ffmpeg runs.
        let media = store.mediaDirectory(for: record.id)
        #expect(await eventually { FileManager.default.fileExists(atPath: media.appendingPathComponent("a1_00000.ts").path) })
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("recording.ts").path))

        #expect(await eventually { await store.recording(record.id)?.status == .completed })
        let final = try #require(await store.recording(record.id))
        #expect(launcher.specs.count == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: media.path).sorted()
        #expect(names == ["index.m3u8", "recording.ts"])
        let text = try playlist(in: media)
        #expect(text.contains("#EXT-X-DISCONTINUITY"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect((final.durationSeconds ?? 0) > 0)
        #expect(final.sizeBytes == MediaInspector.stats(in: media).sizeBytes)
    }

    @Test func schedulerKeepsSegmentsWhenTheMergeWouldEatTheFreeDisk() async throws {
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        var options = fastOptions(minFreeBytes: 1_000)
        options.singleFileRecordings = true
        let launcher = FakeLauncher([.exitAfter(0.1, segments: 2, status: 0)])
        let scheduler = RecordingScheduler(store: store, launcher: launcher, options: options, disk: FakeDisk(freeBytes: 2_000))
        let now = Date()
        let (record, _) = try await scheduler.create(
            CreateRecordingRequest(streamURL: streamURL, title: "Tight", start: now, end: now.addingTimeInterval(0.5)),
            deviceID: nil, idempotencyKey: nil
        )
        #expect(await eventually { await store.recording(record.id)?.status == .completed })
        let media = store.mediaDirectory(for: record.id)
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("recording.ts").path))
        #expect(try playlist(in: media).contains("a1_00000.ts"))
    }

    /// Merged but still `recording` (crash before the status write): resuming
    /// would hand the byte-range playlist to ffmpeg's append_list.
    @Test func aMergedRecordingIsFinalizedNotResumedAfterARestart() async throws {
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        let now = Date()
        let record = RecordingRecord(
            streamURL: streamURL, title: "Merged", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60),
            status: .recording, createdAt: now, startedAt: now.addingTimeInterval(-60), attempts: 2
        )
        try await store.insert(record)
        let media = store.mediaDirectory(for: record.id)
        _ = try writeSegmentedRecording(in: media)
        try SingleFileRecording.consolidate(in: media)

        let launcher = FakeLauncher()
        var options = fastOptions()
        options.singleFileRecordings = true
        let scheduler = RecordingScheduler(store: store, launcher: launcher, options: options, disk: FakeDisk())
        await scheduler.recover()

        #expect(await store.recording(record.id)?.status == .completed)
        #expect(launcher.specs.isEmpty)
        await scheduler.shutdown()
    }

    @Test(arguments: [
        ("bytes=0-99", 1000, ByteRange.Resolution.partial(0 ... 99)),
        ("bytes=940-", 1000, .partial(940 ... 999)),
        ("bytes=-100", 1000, .partial(900 ... 999)),
        ("bytes=-5000", 1000, .partial(0 ... 999)),
        ("bytes=900-5000", 1000, .partial(900 ... 999)),
        ("bytes=1000-", 1000, .unsatisfiable),
        ("bytes=-0", 1000, .unsatisfiable),
        ("bytes=0-9,20-29", 1000, .whole),
        ("bytes=9-0", 1000, .whole),
        ("items=0-9", 1000, .whole),
        ("bytes=abc", 1000, .whole),
    ] as [(String, Int64, ByteRange.Resolution)])
    func rangeHeaders(header: String, size: Int64, expected: ByteRange.Resolution) {
        #expect(ByteRange.resolve(header, fileSize: size) == expected)
    }

    @Test(arguments: [
        (nil, false), ("1", true), ("true", true), ("YES", true), ("on", true), ("0", false), ("false", false), ("", false),
    ] as [(String?, Bool)])
    func environmentEnablesSingleFileRecordings(value: String?, expected: Bool) {
        let environment = value.map { ["SINGLE_FILE_RECORDINGS": $0] } ?? [:]
        #expect(RecorderConfig.fromEnvironment(environment).singleFileRecordings == expected)
    }

    @Test func noRangeHeaderMeansTheWholeFile() {
        #expect(ByteRange.resolve(nil, fileSize: 10) == .whole)
    }
}
