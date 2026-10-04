import Foundation
import LumeRecorderKit

/// Server identity + playback-signing secret (`server.json`).
public struct ServerIdentity: Codable, Sendable, Hashable {
    public var id: UUID
    /// Base64 of 32 random bytes; the HMAC key for playback URLs.
    public var playbackSecret: String
    public var createdAt: Date
}

/// A recording as persisted (`recordings.json`). Unlike the public
/// `Recording` DTO it carries the stream URL — which must never leave the
/// server or reach a log.
public struct RecordingRecord: Codable, Sendable, Hashable {
    public var id: UUID
    public var streamURL: URL
    public var title: String
    public var channelName: String?
    public var channelLogoURL: URL?
    public var programmeDescription: String?
    public var sourceRef: String?
    public var start: Date
    public var end: Date
    public var status: RecordingStatus
    public var failureReason: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Number of ffmpeg attempts launched so far.
    public var attempts: Int
    public var createdByDeviceID: UUID?
    public var idempotencyKey: String?
    /// Cached media stats, filled in when the recording finishes.
    public var durationSeconds: Double?
    public var sizeBytes: Int64?

    public init(
        id: UUID = UUID(),
        streamURL: URL,
        title: String,
        channelName: String? = nil,
        channelLogoURL: URL? = nil,
        programmeDescription: String? = nil,
        sourceRef: String? = nil,
        start: Date,
        end: Date,
        status: RecordingStatus = .scheduled,
        failureReason: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        attempts: Int = 0,
        createdByDeviceID: UUID? = nil,
        idempotencyKey: String? = nil,
        durationSeconds: Double? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.title = title
        self.channelName = channelName
        self.channelLogoURL = channelLogoURL
        self.programmeDescription = programmeDescription
        self.sourceRef = sourceRef
        self.start = start
        self.end = end
        self.status = status
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempts = attempts
        self.createdByDeviceID = createdByDeviceID
        self.idempotencyKey = idempotencyKey
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
    }

    /// The public DTO. `media` overrides the cached stats (live recordings).
    public func publicRecording(media: MediaStats? = nil) -> Recording {
        Recording(
            id: id,
            title: title,
            channelName: channelName,
            channelLogoURL: channelLogoURL,
            programmeDescription: programmeDescription,
            sourceRef: sourceRef,
            start: start,
            end: end,
            status: status,
            failureReason: failureReason,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: media?.durationSeconds ?? durationSeconds,
            sizeBytes: media?.sizeBytes ?? sizeBytes
        )
    }
}

/// A paired device (`devices.json`). Only the SHA-256 of its token is kept.
public struct DeviceRecord: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public var publicDevice: PairedDevice {
        PairedDevice(id: id, name: name, pairedAt: pairedAt, lastSeenAt: lastSeenAt)
    }
}

/// The single owner of on-disk JSON state. Every mutation is written through
/// immediately with an atomic temp-file + rename.
public actor RecorderStore {
    public nonisolated let directory: URL
    public nonisolated let identity: ServerIdentity

    private var recordingsByID: [UUID: RecordingRecord]
    private var devicesByID: [UUID: DeviceRecord]
    /// When each device's `lastSeenAt` was last written to disk.
    private var lastSeenPersisted: [UUID: Date] = [:]

    private nonisolated var serverFile: URL { directory.appendingPathComponent("server.json") }
    private nonisolated var recordingsFile: URL { directory.appendingPathComponent("recordings.json") }
    private nonisolated var devicesFile: URL { directory.appendingPathComponent("devices.json") }
    public nonisolated var recordingsDirectory: URL { directory.appendingPathComponent("recordings", isDirectory: true) }

    /// Opens (or initialises) the store in `directory`.
    public init(directory: URL, now: Date = Date()) throws {
        self.directory = directory
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("recordings", isDirectory: true),
            withIntermediateDirectories: true
        )
        AtomicFile.removeStaleTempFiles(in: directory)

        let serverURL = directory.appendingPathComponent("server.json")
        if let existing = try Self.load(ServerIdentity.self, from: serverURL) {
            identity = existing
        } else {
            let fresh = ServerIdentity(
                id: UUID(),
                playbackSecret: Data(Secrets.randomBytes(32)).base64EncodedString(),
                createdAt: now
            )
            try AtomicFile.write(Self.encode(fresh), to: serverURL)
            identity = fresh
        }

        let recordings = try Self.load([RecordingRecord].self, from: directory.appendingPathComponent("recordings.json")) ?? []
        recordingsByID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let devices = try Self.load([DeviceRecord].self, from: directory.appendingPathComponent("devices.json")) ?? []
        devicesByID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Recordings

    /// All recordings, newest start first.
    public func recordings() -> [RecordingRecord] {
        recordingsByID.values.sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start > rhs.start : lhs.createdAt > rhs.createdAt
        }
    }

    public func recording(_ id: UUID) -> RecordingRecord? {
        recordingsByID[id]
    }

    public func recording(idempotencyKey: String, deviceID: UUID) -> RecordingRecord? {
        recordingsByID.values.first { $0.idempotencyKey == idempotencyKey && $0.createdByDeviceID == deviceID }
    }

    public func insert(_ record: RecordingRecord) throws {
        recordingsByID[record.id] = record
        try persistRecordings()
    }

    /// Mutates and persists one recording; returns the updated value.
    @discardableResult
    public func update(_ id: UUID, _ body: @Sendable (inout RecordingRecord) -> Void) throws -> RecordingRecord? {
        guard var record = recordingsByID[id] else { return nil }
        body(&record)
        guard record != recordingsByID[id] else { return record }
        recordingsByID[id] = record
        try persistRecordings()
        return record
    }

    public func removeRecording(_ id: UUID) throws {
        guard recordingsByID.removeValue(forKey: id) != nil else { return }
        try persistRecordings()
    }

    public nonisolated func mediaDirectory(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    // MARK: Devices

    public func devices() -> [DeviceRecord] {
        devicesByID.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func device(tokenHash: String) -> DeviceRecord? {
        devicesByID.values.first { Secrets.constantTimeEquals($0.tokenHash, tokenHash) }
    }

    public func addDevice(_ device: DeviceRecord) throws {
        devicesByID[device.id] = device
        lastSeenPersisted[device.id] = device.lastSeenAt
        try persistDevices()
    }

    /// Returns whether a device was removed.
    @discardableResult
    public func removeDevice(_ id: UUID) throws -> Bool {
        guard devicesByID.removeValue(forKey: id) != nil else { return false }
        try persistDevices()
        return true
    }

    /// Records activity; hits the disk at most once a minute per device.
    public func touchDevice(_ id: UUID, at date: Date) {
        guard devicesByID[id] != nil else { return }
        devicesByID[id]?.lastSeenAt = date
        if let persisted = lastSeenPersisted[id], date.timeIntervalSince(persisted) < 60 { return }
        lastSeenPersisted[id] = date
        try? persistDevices()
    }

    // MARK: Persistence

    private func persistRecordings() throws {
        try AtomicFile.write(Self.encode(recordings()), to: recordingsFile)
    }

    private func persistDevices() throws {
        try AtomicFile.write(Self.encode(devices()), to: devicesFile)
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = LumeRecorderCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try LumeRecorderCoding.makeDecoder().decode(T.self, from: data)
    }
}
