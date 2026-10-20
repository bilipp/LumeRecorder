import Foundation

/// A single `Range: bytes=…` request header (RFC 9110 §14.1.2). Byte-range
/// playlists (`SINGLE_FILE_RECORDINGS`) make players fetch every segment
/// this way. Multi-range requests are answered with the whole file, which
/// the RFC allows.
enum ByteRange {
    enum Resolution: Equatable {
        /// No usable range header: send the whole file with 200.
        case whole
        /// Send these bytes with 206.
        case partial(ClosedRange<Int64>)
        /// No byte of the range lies in the file: 416.
        case unsatisfiable
    }

    static func resolve(_ header: String?, fileSize: Int64) -> Resolution {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes=")
        else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // Suffix range: the final N bytes.
            guard let suffix = Int64(last) else { return .whole }
            guard suffix > 0, fileSize > 0 else { return .unsatisfiable }
            return .partial(max(0, fileSize - suffix) ... fileSize - 1)
        }
        guard let start = Int64(first) else { return .whole }
        let end: Int64
        if last.isEmpty {
            end = fileSize - 1
        } else {
            guard let parsed = Int64(last), parsed >= start else { return .whole }
            end = min(parsed, fileSize - 1)
        }
        guard start < fileSize else { return .unsatisfiable }
        return .partial(start ... end)
    }
}
