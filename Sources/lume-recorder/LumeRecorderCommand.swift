import ArgumentParser
import Foundation
import Logging
import RecorderCore

@main
struct LumeRecorderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lume-recorder",
        abstract: "Self-hosted DVR recording server for the Lume IPTV app.",
        version: RecorderVersion.current,
        subcommands: [Serve.self, Pair.self, ServerID.self],
        defaultSubcommand: Serve.self
    )
}

/// Flags mirror the environment variables; a flag wins over its variable.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the recording server (default).")

    @Option(help: "Bind address (env HOST, default 0.0.0.0).") var host: String?
    @Option(help: "HTTP port (env PORT, default 8090).") var port: Int?
    @Option(name: .customLong("data-dir"), help: "State + recordings directory (env DATA_DIR, default ./data).") var dataDir: String?
    @Option(name: .customLong("max-concurrent"), help: "Simultaneous recordings (env MAX_CONCURRENT, default 4).") var maxConcurrent: Int?
    @Option(name: .customLong("min-free-gb"), help: "Minimum free disk in GB (env MIN_FREE_GB, default 2).") var minFreeGB: Double?
    @Option(name: .customLong("server-name"), help: "Display name (env SERVER_NAME, default hostname).") var serverName: String?
    @Option(name: .customLong("public-url"), help: "Base URL for playback links without a Host header (env PUBLIC_URL).") var publicURL: String?
    @Option(name: .customLong("ffmpeg-path"), help: "ffmpeg executable (env FFMPEG_PATH, default ffmpeg on PATH).") var ffmpegPath: String?
    @Option(name: .customLong("log-level"), help: "trace|debug|info|notice|warning|error|critical (env LOG_LEVEL, default info).") var logLevel: String?
    @Flag(name: .customLong("no-bonjour"), help: "Don't advertise via Bonjour (env BONJOUR=0).") var noBonjour = false

    func run() async throws {
        var config = RecorderConfig.fromEnvironment()
        if let host { config.host = host }
        if let port { config.port = port }
        if let dataDir { config.dataDirectory = URL(fileURLWithPath: dataDir) }
        if let maxConcurrent { config.maxConcurrent = maxConcurrent }
        if let minFreeGB { config.minFreeGB = minFreeGB }
        if let serverName { config.serverName = serverName }
        if let publicURL { config.publicURL = URL(string: publicURL) }
        if let ffmpegPath { config.ffmpegPath = ffmpegPath }
        if let logLevel {
            guard let level = Logger.Level(rawValue: logLevel.lowercased()) else {
                throw ValidationError("Unknown log level \(logLevel)")
            }
            config.logLevel = level
        }
        if noBonjour { config.bonjourEnabled = false }
        guard config.maxConcurrent >= 1 else { throw ValidationError("max-concurrent must be at least 1") }

        let level = config.logLevel
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }
        var logger = Logger(label: "lume-recorder")
        logger.logLevel = level
        try await RecorderServer.run(config: config, logger: logger)
    }
}

/// Prints the current pairing code from `DATA_DIR/pairing-code.json`, so
/// `docker exec lume-recorder lume-recorder pair` works.
struct Pair: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the current pairing code of a running server.")

    @Option(name: .customLong("data-dir"), help: "Data directory (env DATA_DIR, default ./data).") var dataDir: String?

    func run() throws {
        var config = RecorderConfig.fromEnvironment()
        if let dataDir { config.dataDirectory = URL(fileURLWithPath: dataDir) }
        guard let code = PairingCodeFile.read(from: config.dataDirectory) else {
            throw ValidationError("No pairing code found in \(config.dataDirectory.path). Is the server running with this DATA_DIR?")
        }
        let remaining = code.expiresAt.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ValidationError("The last pairing code expired. Is the server running?")
        }
        let minutes = Int((remaining / 60).rounded(.up))
        print("Pairing code: \(code.formatted) (valid \(minutes) more min)")
    }
}

/// Prints the persisted server id (creating `server.json` on first use). The
/// Docker entrypoint uses it for the avahi TXT record before the server starts.
struct ServerID: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server-id",
        abstract: "Print the stable server id (creates it if missing).",
        shouldDisplay: false
    )

    @Option(name: .customLong("data-dir"), help: "Data directory (env DATA_DIR, default ./data).") var dataDir: String?

    func run() throws {
        var config = RecorderConfig.fromEnvironment()
        if let dataDir { config.dataDirectory = URL(fileURLWithPath: dataDir) }
        let store = try RecorderStore(directory: config.dataDirectory)
        print(store.identity.id.uuidString.lowercased())
    }
}
