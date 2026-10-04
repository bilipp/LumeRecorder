import Foundation

// MARK: - API constants

/// Version and path constants of the HTTP API this Kit speaks.
public enum LumeRecorderAPI {
    /// The API version this Kit implements. Bumped only on breaking changes.
    public static let version = 1
    /// Path prefix of every JSON endpoint.
    public static let pathPrefix = "/api/v1"
    /// Header carrying the client-chosen idempotency key on `POST /recordings`.
    public static let idempotencyKeyHeader = "Idempotency-Key"
}

/// Machine-readable error codes the server returns in `ErrorResponse.error.code`.
public enum LumeRecorderErrorCode {
    public static let unauthorized = "unauthorized"
    public static let pairingInvalid = "pairing_invalid"
    public static let rateLimited = "rate_limited"
    public static let invalidRequest = "invalid_request"
    public static let notFound = "not_found"
    public static let concurrencyLimit = "concurrency_limit"
    public static let insufficientStorage = "insufficient_storage"
    public static let notPlayable = "not_playable"
    public static let forbidden = "forbidden"
    public static let internalError = "internal_error"
}

// MARK: - Server

public struct ServerInfo: Codable, Sendable, Hashable {
    /// Stable server identity, persisted in the server's data directory.
    public var id: UUID
    public var name: String
    public var version: String
    public var apiVersion: Int

    public init(id: UUID, name: String, version: String, apiVersion: Int) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
    }
}

public struct ServerStatus: Codable, Sendable, Hashable {
    public var activeRecordings: Int
    public var scheduledRecordings: Int
    public var freeDiskBytes: Int64
    public var totalDiskBytes: Int64
    public var maxConcurrent: Int

    public init(
        activeRecordings: Int,
        scheduledRecordings: Int,
        freeDiskBytes: Int64,
        totalDiskBytes: Int64,
        maxConcurrent: Int
    ) {
        self.activeRecordings = activeRecordings
        self.scheduledRecordings = scheduledRecordings
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.maxConcurrent = maxConcurrent
    }
}

// MARK: - Pairing

public struct PairRequest: Codable, Sendable, Hashable {
    /// The 6-digit code shown in the server log (spaces are ignored).
    public var code: String
    public var deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

public struct PairResponse: Codable, Sendable, Hashable {
    /// Bearer token for every authenticated call. Store it in the Keychain.
    public var token: String
    public var deviceID: UUID
    public var server: ServerInfo

    public init(token: String, deviceID: UUID, server: ServerInfo) {
        self.token = token
        self.deviceID = deviceID
        self.server = server
    }
}

public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: UUID, name: String, pairedAt: Date, lastSeenAt: Date?) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - Recordings

/// Lifecycle state of a recording.
///
/// Decoding never fails: a state this client doesn't know yet decodes as
/// `.unknown(rawValue)` and re-encodes to the same raw value.
public enum RecordingStatus: Sendable, Hashable, Codable, CustomStringConvertible {
    case scheduled
    case recording
    case completed
    case failed
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "scheduled": self = .scheduled
        case "recording": self = .recording
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scheduled: "scheduled"
        case .recording: "recording"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case let .unknown(raw): raw
        }
    }

    /// `scheduled` or `recording` — the server still has work to do.
    public var isPending: Bool {
        self == .scheduled || self == .recording
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Recording: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var channelName: String?
    public var channelLogoURL: URL?
    public var programmeDescription: String?
    /// Opaque, Lume-defined reference echoed back unchanged.
    public var sourceRef: String?
    public var start: Date
    public var end: Date
    public var status: RecordingStatus
    public var failureReason: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Media duration recorded so far, in seconds.
    public var durationSeconds: Double?
    /// Bytes on disk used by the recording's media.
    public var sizeBytes: Int64?

    public init(
        id: UUID,
        title: String,
        channelName: String? = nil,
        channelLogoURL: URL? = nil,
        programmeDescription: String? = nil,
        sourceRef: String? = nil,
        start: Date,
        end: Date,
        status: RecordingStatus,
        failureReason: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        durationSeconds: Double? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.id = id
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
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
    }
}

public struct CreateRecordingRequest: Codable, Sendable, Hashable {
    /// The provider stream URL (http/https). It may carry credentials; the
    /// server never echoes or logs it.
    public var streamURL: URL
    public var title: String
    public var channelName: String?
    public var channelLogoURL: URL?
    public var programmeDescription: String?
    public var start: Date
    public var end: Date
    /// Opaque, Lume-defined reference (e.g. channel + programme id).
    public var sourceRef: String?

    public init(
        streamURL: URL,
        title: String,
        channelName: String? = nil,
        channelLogoURL: URL? = nil,
        programmeDescription: String? = nil,
        start: Date,
        end: Date,
        sourceRef: String? = nil
    ) {
        self.streamURL = streamURL
        self.title = title
        self.channelName = channelName
        self.channelLogoURL = channelLogoURL
        self.programmeDescription = programmeDescription
        self.start = start
        self.end = end
        self.sourceRef = sourceRef
    }
}

/// A short-lived, path-signed HLS URL for one recording.
public struct PlaybackGrant: Codable, Sendable, Hashable {
    public var url: URL
    public var expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

// MARK: - Errors

/// The JSON body of every non-2xx response: `{"error":{"code":…,"message":…}}`.
public struct ErrorResponse: Codable, Sendable, Hashable {
    public struct Body: Codable, Sendable, Hashable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var error: Body

    public init(error: Body) {
        self.error = error
    }

    public init(code: String, message: String) {
        error = Body(code: code, message: message)
    }
}
