import Foundation
import LumeRecorderKit
@testable import RecorderCore
import Testing

@Suite("RecorderStore persistence")
struct StoreTests {
    @Test func identityIsCreatedOnceAndStable() throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let first = try RecorderStore(directory: dir)
        let second = try RecorderStore(directory: dir)
        #expect(first.identity.id == second.identity.id)
        #expect(first.identity.playbackSecret == second.identity.playbackSecret)
        #expect(Data(base64Encoded: first.identity.playbackSecret)?.count == 32)
    }

    @Test func recordingsAndDevicesSurviveARestart() async throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let now = wholeSecond()
        let record = RecordingRecord(
            streamURL: URL(string: "http://provider.example/live/u/p/1.ts")!,
            title: "News",
            channelName: "One",
            start: now,
            end: now.addingTimeInterval(600),
            status: .recording,
            createdAt: now,
            startedAt: now,
            attempts: 2,
            createdByDeviceID: UUID(),
            idempotencyKey: "k"
        )
        let device = DeviceRecord(id: UUID(), name: "TV", tokenHash: Secrets.sha256Hex("tok"), pairedAt: now, lastSeenAt: now)

        let store = try RecorderStore(directory: dir)
        try await store.insert(record)
        try await store.addDevice(device)
        try await store.update(record.id) { $0.failureReason = "x" }

        let reopened = try RecorderStore(directory: dir)
        var expected = record
        expected.failureReason = "x"
        #expect(await reopened.recording(record.id) == expected)
        #expect(await reopened.devices() == [device])
        #expect(await reopened.device(tokenHash: Secrets.sha256Hex("tok"))?.id == device.id)
        #expect(await reopened.device(tokenHash: Secrets.sha256Hex("other")) == nil)
    }

    @Test func writesAreAtomicAndLeaveNoTempFiles() async throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        // A temp file left by a crash mid-write is cleaned up on open…
        let stale = dir.appendingPathComponent(".recordings.json.DEAD\(AtomicFile.tempSuffix)")
        FileManager.default.createFile(atPath: stale.path, contents: Data("{partial".utf8))
        let store = try RecorderStore(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: stale.path))

        // …and many writes leave only complete, decodable files behind.
        let now = wholeSecond()
        for index in 0 ..< 25 {
            try await store.insert(RecordingRecord(
                streamURL: URL(string: "http://p/\(index).ts")!, title: "T\(index)",
                start: now.addingTimeInterval(Double(index)), end: now.addingTimeInterval(Double(index) + 60), createdAt: now
            ))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasSuffix(AtomicFile.tempSuffix) })
        let data = try Data(contentsOf: dir.appendingPathComponent("recordings.json"))
        let decoded = try LumeRecorderCoding.makeDecoder().decode([RecordingRecord].self, from: data)
        #expect(decoded.count == 25)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("recordings.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func recordingsAreNewestStartFirst() async throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let store = try RecorderStore(directory: dir)
        let now = wholeSecond()
        for offset in [10.0, 30, 20] {
            try await store.insert(RecordingRecord(streamURL: URL(string: "http://p/x.ts")!, title: "\(Int(offset))", start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 60), createdAt: now))
        }
        #expect(await store.recordings().map(\.title) == ["30", "20", "10"])
    }

    @Test func corruptStateFailsLoudlyInsteadOfStartingEmpty() throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        _ = try RecorderStore(directory: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("recordings.json"))
        #expect(throws: (any Error).self) { _ = try RecorderStore(directory: dir) }
    }

    @Test func lastSeenIsThrottledOnDisk() async throws {
        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let now = wholeSecond()
        let store = try RecorderStore(directory: dir)
        let device = DeviceRecord(id: UUID(), name: "TV", tokenHash: "h", pairedAt: now, lastSeenAt: now)
        try await store.addDevice(device)
        await store.touchDevice(device.id, at: now.addingTimeInterval(10))
        let snapshot = try RecorderStore(directory: dir)
        #expect(await snapshot.devices().first?.lastSeenAt == now) // not yet persisted
        #expect(await store.devices().first?.lastSeenAt == now.addingTimeInterval(10)) // but live in memory
        await store.touchDevice(device.id, at: now.addingTimeInterval(120))
        let later = try RecorderStore(directory: dir)
        #expect(await later.devices().first?.lastSeenAt == now.addingTimeInterval(120))
    }
}
