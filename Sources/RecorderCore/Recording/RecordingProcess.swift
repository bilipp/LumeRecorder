import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// Everything one ffmpeg attempt needs.
public struct RecordingAttemptSpec: Sendable {
    public var recordingID: UUID
    public var streamURL: URL
    public var outputDirectory: URL
    /// 1-based attempt number; names the segments `a<attempt>_%05d.ts`.
    public var attempt: Int
    /// Backstop for `-t`: the wall-clock time left until the recording's end.
    public var maxDuration: TimeInterval
    /// The source is (or behaves like) an HLS playlist, so the HLS demuxer's
    /// `-extension_picky 0` may be passed. Only the HLS demuxer knows that
    /// option: ffmpeg refuses to open any other input that carries it.
    public var hlsInput: Bool

    public init(
        recordingID: UUID,
        streamURL: URL,
        outputDirectory: URL,
        attempt: Int,
        maxDuration: TimeInterval,
        hlsInput: Bool? = nil
    ) {
        self.recordingID = recordingID
        self.streamURL = streamURL
        self.outputDirectory = outputDirectory
        self.attempt = attempt
        self.maxDuration = maxDuration
        self.hlsInput = hlsInput ?? FFmpegArguments.looksLikeHLS(streamURL)
    }
}

/// A running recorder process. The scheduler only ever talks to this
/// protocol, so tests can substitute a fake without network or ffmpeg.
public protocol RecordingProcess: Sendable {
    /// Suspends until the process has exited; returns its exit status.
    func waitForExit() async -> Int32
    /// SIGINT — ffmpeg finalizes the playlist (writes `#EXT-X-ENDLIST`).
    func interrupt()
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
    /// The last few KB of stderr. May contain the stream URL: redact before use.
    func stderrTail() -> String
}

public protocol RecordingProcessLauncher: Sendable {
    func launch(_ spec: RecordingAttemptSpec) throws -> any RecordingProcess
}

public enum RecordingLaunchError: Error, CustomStringConvertible {
    case ffmpegNotFound(String)

    public var description: String {
        switch self {
        case let .ffmpegNotFound(path): "ffmpeg_not_found: \(path)"
        }
    }
}

// MARK: - ffmpeg

/// Optional ffmpeg input options, detected once at startup from `ffmpeg -h long`
/// and `ffmpeg -h demuxer=hls` (Ubuntu noble ships ffmpeg 6.1, which lacks
/// `-readrate_catchup` and may lack `-extension_picky`).
public struct FFmpegCapabilities: Sendable, Hashable {
    public var readRate: Bool
    public var readRateInitialBurst: Bool
    public var readRateCatchup: Bool
    /// The HLS demuxer's `extension_picky` option. Turning it off lets
    /// playlists whose WebVTT subtitle rendition is packaged as `.mp4` open
    /// (otherwise: "detected format webvtt extension vtt mismatches allowed
    /// extensions", exit 183 on every attempt).
    public var hlsExtensionPicky: Bool

    public init(readRate: Bool, readRateInitialBurst: Bool, readRateCatchup: Bool, hlsExtensionPicky: Bool) {
        self.readRate = readRate
        self.readRateInitialBurst = readRateInitialBurst
        self.readRateCatchup = readRateCatchup
        self.hlsExtensionPicky = hlsExtensionPicky
    }

    public static let all = FFmpegCapabilities(readRate: true, readRateInitialBurst: true, readRateCatchup: true, hlsExtensionPicky: true)
    public static let none = FFmpegCapabilities(readRate: false, readRateInitialBurst: false, readRateCatchup: false, hlsExtensionPicky: false)

    public static func detect(executable: URL) -> FFmpegCapabilities {
        guard let help = helpText(executable: executable, arguments: ["-hide_banner", "-h", "long"]) else { return .none }
        let hls = helpText(executable: executable, arguments: ["-hide_banner", "-h", "demuxer=hls"]) ?? ""
        return FFmpegCapabilities(
            readRate: help.contains("-readrate "),
            readRateInitialBurst: help.contains("-readrate_initial_burst"),
            readRateCatchup: help.contains("-readrate_catchup"),
            hlsExtensionPicky: hls.contains("extension_picky")
        )
    }

    private static func helpText(executable: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum FFmpegArguments {
    public static let segmentSeconds = 6

    /// The argument vector for one attempt (run with the recording directory
    /// as the working directory). Contains the stream URL — never log it.
    public static func make(for spec: RecordingAttemptSpec, capabilities: FFmpegCapabilities) -> [String] {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "warning",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_on_network_error", "1",
            "-reconnect_delay_max", "30",
            "-rw_timeout", "15000000",
        ]
        // Pace reading at real time: VOD-style "live" sources would otherwise be
        // slurped at network speed. The burst lets a live source's backlog in.
        if capabilities.readRate {
            arguments += ["-readrate", "1"]
            if capabilities.readRateInitialBurst { arguments += ["-readrate_initial_burst", "10"] }
            if capabilities.readRateCatchup { arguments += ["-readrate_catchup", "2"] }
        }
        // HLS sources only: some masters package their WebVTT subtitle
        // rendition as `.mp4`, which the picky extension check rejects before
        // the first segment loads. Any other demuxer refuses the option.
        if capabilities.hlsExtensionPicky, spec.hlsInput {
            arguments += ["-extension_picky", "0"]
        }
        arguments += [
            "-i", spec.streamURL.absoluteString,
            "-t", String(format: "%.3f", max(1, spec.maxDuration)),
            // Default stream selection (best video + best audio): an explicit
            // `-map 0:v? -map 0:a?` copies *every* variant of an HLS master.
            "-sn", "-dn",
            "-c", "copy",
            "-f", "hls",
            "-hls_time", String(segmentSeconds),
            "-hls_list_size", "0",
            "-hls_playlist_type", "event",
            "-hls_flags", "append_list+independent_segments",
            "-hls_segment_filename", "a\(spec.attempt)_%05d.ts",
            PlaybackSigner.playlistName,
        ]
        return arguments
    }

    /// A stream URL whose path names an HLS playlist (`.m3u8` / `.m3u`).
    public static func looksLikeHLS(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "m3u8" || pathExtension == "m3u"
    }

    /// ffmpeg's HLS demuxer rejected a segment or rendition by extension: the
    /// source is HLS even though its URL doesn't say so.
    static func isHLSExtensionMismatch(_ stderr: String) -> Bool {
        stderr.contains("mismatches allowed extensions")
    }

    /// The input wasn't HLS after all: its demuxer refused `-extension_picky`.
    static func isUnknownExtensionPickyOption(_ stderr: String) -> Bool {
        stderr.contains("Option extension_picky not found")
    }

    /// Resolves `ffmpeg` (bare name → `PATH` lookup, or a path).
    public static func resolveExecutable(_ nameOrPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        if nameOrPath.contains("/") {
            return fileManager.isExecutableFile(atPath: nameOrPath) ? URL(fileURLWithPath: nameOrPath) : nil
        }
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(nameOrPath)"
            if fileManager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

/// Launches real ffmpeg processes.
public struct FFmpegLauncher: RecordingProcessLauncher {
    public let executable: URL?
    public let configuredPath: String
    public let capabilities: FFmpegCapabilities

    /// `capabilities` defaults to detection via `ffmpeg -h long`.
    public init(path: String, capabilities: FFmpegCapabilities? = nil) {
        configuredPath = path
        let executable = FFmpegArguments.resolveExecutable(path)
        self.executable = executable
        self.capabilities = capabilities ?? executable.map { FFmpegCapabilities.detect(executable: $0) } ?? .none
    }

    public func launch(_ spec: RecordingAttemptSpec) throws -> any RecordingProcess {
        guard let executable else { throw RecordingLaunchError.ffmpegNotFound(configuredPath) }
        return try FFmpegProcess(
            executable: executable,
            arguments: FFmpegArguments.make(for: spec, capabilities: capabilities),
            workingDirectory: spec.outputDirectory
        )
    }
}

/// A Foundation `Process` running ffmpeg, stdin closed, stderr captured.
final class FFmpegProcess: RecordingProcess, @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var tail = Data()
    private var exitStatus: Int32?
    private var stderrClosed = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private static let tailLimit = 4096

    init(executable: URL, arguments: [String], workingDirectory: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus, stderrClosed: false)
        }
        try process.run()

        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                self?.appendStderr(chunk)
            }
            try? reader.close()
            self?.finish(status: nil, stderrClosed: true)
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status = exitStatus, stderrClosed {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func interrupt() { signal(SIGINT) }
    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }

    func stderrTail() -> String {
        lock.withLock { String(decoding: tail, as: UTF8.self) }
    }

    private func signal(_ signal: Int32) {
        let pid = process.processIdentifier
        let running = lock.withLock { exitStatus == nil }
        guard running, pid > 0 else { return }
        _ = sendSignal(pid, signal)
    }

    private func appendStderr(_ chunk: Data) {
        lock.withLock {
            tail.append(chunk)
            if tail.count > Self.tailLimit { tail = tail.suffix(Self.tailLimit) }
        }
    }

    /// Resumes waiters once the process has exited *and* stderr hit EOF, so
    /// the tail is complete when the scheduler reads it.
    private func finish(status: Int32?, stderrClosed closed: Bool) {
        lock.lock()
        if let status { exitStatus = status }
        if closed { stderrClosed = true }
        guard let final = exitStatus, stderrClosed else {
            lock.unlock()
            return
        }
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: final)
        }
    }
}

private func sendSignal(_ pid: Int32, _ signal: Int32) -> Int32 {
    kill(pid, signal)
}
