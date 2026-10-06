import Foundation
import Logging

/// Server version reported by `GET /api/v1/info` and in Bonjour TXT records.
public enum RecorderVersion {
    public static let current = "0.1.1"
}

/// Returns the current time. Injected so tests can drive time.
public typealias NowProvider = @Sendable () -> Date

/// Runtime configuration. Every field maps to an environment variable (and a
/// matching CLI flag on `lume-recorder serve`).
public struct RecorderConfig: Sendable {
    /// `HOST` — bind address.
    public var host: String
    /// `PORT` — HTTP port.
    public var port: Int
    /// `DATA_DIR` — JSON state, secrets and recordings live here.
    public var dataDirectory: URL
    /// `MAX_CONCURRENT` — simultaneous ffmpeg processes.
    public var maxConcurrent: Int
    /// `MIN_FREE_GB` — refuse/fail recordings below this much free disk.
    public var minFreeGB: Double
    /// `SERVER_NAME` — display name; defaults to the hostname.
    public var serverName: String
    /// `PUBLIC_URL` — base URL for playback links when a request has no Host header.
    public var publicURL: URL?
    /// `FFMPEG_PATH` — executable name or path; bare names are looked up on `PATH`.
    public var ffmpegPath: String
    /// `LOG_LEVEL` — trace, debug, info, notice, warning, error, critical.
    public var logLevel: Logger.Level
    /// `BONJOUR` — `0`/`false` disables the macOS NetService advertisement.
    public var bonjourEnabled: Bool
    /// Lifetime of playback grants.
    public var playbackGrantLifetime: TimeInterval = 12 * 3600

    public init(
        host: String = "0.0.0.0",
        port: Int = 8090,
        dataDirectory: URL = URL(fileURLWithPath: "./data"),
        maxConcurrent: Int = 4,
        minFreeGB: Double = 2,
        serverName: String = RecorderConfig.defaultServerName(),
        publicURL: URL? = nil,
        ffmpegPath: String = "ffmpeg",
        logLevel: Logger.Level = .info,
        bonjourEnabled: Bool = true
    ) {
        self.host = host
        self.port = port
        self.dataDirectory = dataDirectory
        self.maxConcurrent = maxConcurrent
        self.minFreeGB = minFreeGB
        self.serverName = serverName
        self.publicURL = publicURL
        self.ffmpegPath = ffmpegPath
        self.logLevel = logLevel
        self.bonjourEnabled = bonjourEnabled
    }

    /// Builds a config from environment variables, falling back to defaults.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RecorderConfig {
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        var config = RecorderConfig()
        if let host = value("HOST") { config.host = host }
        if let port = value("PORT").flatMap(Int.init) { config.port = port }
        if let dir = value("DATA_DIR") { config.dataDirectory = URL(fileURLWithPath: dir) }
        if let max = value("MAX_CONCURRENT").flatMap(Int.init) { config.maxConcurrent = max }
        if let gb = value("MIN_FREE_GB").flatMap(Double.init) { config.minFreeGB = gb }
        if let name = value("SERVER_NAME") { config.serverName = name }
        if let url = value("PUBLIC_URL").flatMap(URL.init(string:)) { config.publicURL = url }
        if let ffmpeg = value("FFMPEG_PATH") { config.ffmpegPath = ffmpeg }
        if let level = value("LOG_LEVEL").flatMap({ Logger.Level(rawValue: $0.lowercased()) }) { config.logLevel = level }
        if let bonjour = value("BONJOUR") { config.bonjourEnabled = !["0", "false", "no", "off"].contains(bonjour.lowercased()) }
        return config
    }

    /// Minimum free bytes derived from `minFreeGB`.
    public var minFreeBytes: Int64 { Int64(minFreeGB * 1_000_000_000) }

    /// The machine's short hostname (no domain suffix), never blocking on DNS.
    public static func defaultServerName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "LumeRecorder" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self).split(separator: ".").first.map(String.init) ?? ""
        return name.isEmpty ? "LumeRecorder" : name
    }
}
