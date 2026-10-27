import Foundation
import Logging

/// Appends log lines to `~/Library/Logs/LumeRecorder/lume-recorder.log`, which
/// the menu opens in Console. RecorderCore redacts stream URLs before logging.
struct FileLogHandler: LogHandler {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LumeRecorder/lume-recorder.log")

    private static let sink = LogFileSink(url: fileURL)

    let label: String
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    init(label: String, logLevel: Logger.Level) {
        self.label = label
        self.logLevel = logLevel
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let stamp = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current))
        Self.sink.write("\(stamp) \(event.level) [\(event.source)] \(event.message)\n")
    }
}

/// Serializes writes to the log file. Rolls the file over to `.1` past 5 MB at launch.
private final class LogFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?

    init(url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            let old = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: url, to: old)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.withLock {
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}
