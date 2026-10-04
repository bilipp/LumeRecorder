import Foundation

/// Duration and size of a recording's media on disk.
public struct MediaStats: Sendable, Hashable {
    public var segmentCount: Int
    public var durationSeconds: Double
    public var sizeBytes: Int64
    public var hasEndList: Bool

    public static let empty = MediaStats(segmentCount: 0, durationSeconds: 0, sizeBytes: 0, hasEndList: false)
}

/// Minimal reading/patching of the media playlist ffmpeg writes.
public enum HLSPlaylist {
    public static let endList = "#EXT-X-ENDLIST"

    public struct Summary: Sendable, Hashable {
        public var segmentCount: Int
        public var durationSeconds: Double
        public var hasEndList: Bool
    }

    public static func summarize(_ text: String) -> Summary {
        var count = 0
        var duration = 0.0
        var hasEndList = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
                duration += Double(value) ?? 0
            } else if line == endList {
                hasEndList = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                count += 1
            }
        }
        return Summary(segmentCount: count, durationSeconds: duration, hasEndList: hasEndList)
    }

    /// The playlist without `#EXT-X-ENDLIST` — served while a recording is
    /// still running so a player in the gap between two ffmpeg attempts keeps
    /// polling instead of treating the event as finished.
    public static func removingEndList(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != endList }
            .joined(separator: "\n")
    }

    /// Appends `#EXT-X-ENDLIST` if ffmpeg didn't (killed, crashed). Returns
    /// whether the file was changed.
    @discardableResult
    public static func ensureEndList(at url: URL) throws -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        guard !summarize(text).hasEndList else { return false }
        var patched = text
        if !patched.hasSuffix("\n") { patched += "\n" }
        patched += endList + "\n"
        try AtomicFile.write(Data(patched.utf8), to: url, permissions: 0o644)
        return true
    }
}

/// Reads stats for a recording directory.
public enum MediaInspector {
    public static func stats(in directory: URL) -> MediaStats {
        let fileManager = FileManager.default
        let playlistURL = directory.appendingPathComponent(PlaybackSigner.playlistName)
        var stats = MediaStats.empty
        if let data = fileManager.contents(atPath: playlistURL.path), let text = String(data: data, encoding: .utf8) {
            let summary = HLSPlaylist.summarize(text)
            stats.segmentCount = summary.segmentCount
            stats.durationSeconds = summary.durationSeconds
            stats.hasEndList = summary.hasEndList
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".ts") || name.hasSuffix(".m3u8") {
            let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            stats.sizeBytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return stats
    }
}
