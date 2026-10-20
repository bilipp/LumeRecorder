import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// `SINGLE_FILE_RECORDINGS`: once a recording is finalized, its segments are
/// concatenated into one `recording.ts` and `index.m3u8` is rewritten to
/// address it with `#EXT-X-BYTERANGE`. ffmpeg still records plain segments,
/// so live playback and `append_list` retries work unchanged.
///
/// MPEG-TS concatenates byte for byte. Attempt boundaries keep their
/// `#EXT-X-DISCONTINUITY` in the playlist.
///
/// Crash-safe: the file is built under a temporary name and renamed, then the
/// playlist is replaced atomically, and only then are the segments deleted.
/// A crash at any point leaves either the old or the new layout, and running
/// it again finishes the job.
public enum SingleFileRecording {
    public static let fileName = "recording.ts"
    static let partialName = "recording.partial"
    /// `EXT-X-BYTERANGE` needs protocol version 4.
    static let minimumVersion = 4
    private static let chunkLength = 1 << 20

    /// True once `index.m3u8` addresses `recording.ts` only.
    public static func isConsolidated(in directory: URL) -> Bool {
        guard let text = playlistText(in: directory) else { return false }
        let uris = segmentURIs(text)
        return !uris.isEmpty && uris.allSatisfy { $0 == fileName }
    }

    /// Merges the playlist's segments into `recording.ts`. Returns false if
    /// there was nothing to merge (no playlist, no segments, already merged).
    @discardableResult
    public static func consolidate(in directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard let text = playlistText(in: directory) else { return false }
        let uris = segmentURIs(text)
        guard !uris.isEmpty else { return false }
        if uris.allSatisfy({ $0 == fileName }) {
            removeLeftovers(in: directory)
            return false
        }
        // Only flat segment names ffmpeg wrote next to the playlist.
        guard uris.allSatisfy({ PlaybackSigner.isSafeMediaFileName($0) && $0.hasSuffix(".ts") && $0 != fileName }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: directory.path])
        }

        let partial = directory.appendingPathComponent(partialName)
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        var ranges: [(length: Int64, offset: Int64)] = []
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var offset: Int64 = 0
            for uri in uris {
                let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(uri))
                defer { try? input.close() }
                var length: Int64 = 0
                while let chunk = try input.read(upToCount: chunkLength), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    length += Int64(chunk.count)
                }
                ranges.append((length, offset))
                offset += length
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        let target = directory.appendingPathComponent(fileName)
        guard rename(partial.path, target.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: partial)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let playlist = directory.appendingPathComponent(PlaybackSigner.playlistName)
        try AtomicFile.write(Data(rewrite(text, ranges: ranges).utf8), to: playlist, permissions: 0o644)
        removeLeftovers(in: directory)
        return true
    }

    /// `text` with each segment URI replaced by a byte range of `recording.ts`.
    static func rewrite(_ text: String, ranges: [(length: Int64, offset: Int64)]) -> String {
        var lines: [String] = []
        var index = 0
        var sawVersion = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-VERSION:") {
                let version = Int(line.dropFirst("#EXT-X-VERSION:".count)) ?? 0
                lines.append("#EXT-X-VERSION:\(max(version, minimumVersion))")
                sawVersion = true
            } else if !line.isEmpty, !line.hasPrefix("#"), index < ranges.count {
                let range = ranges[index]
                index += 1
                lines.append("#EXT-X-BYTERANGE:\(range.length)@\(range.offset)")
                lines.append(fileName)
            } else {
                lines.append(String(rawLine))
            }
        }
        if !sawVersion, let header = lines.firstIndex(of: "#EXTM3U") {
            lines.insert("#EXT-X-VERSION:\(minimumVersion)", at: header + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Segment URIs in playlist order.
    static func segmentURIs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func playlistText(in directory: URL) -> String? {
        let playlist = directory.appendingPathComponent(PlaybackSigner.playlistName)
        guard let data = FileManager.default.contents(atPath: playlist.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every `.ts` besides `recording.ts`, plus a partial file from a crash.
    private static func removeLeftovers(in directory: URL) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where (name.hasSuffix(".ts") && name != fileName) || name == partialName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
