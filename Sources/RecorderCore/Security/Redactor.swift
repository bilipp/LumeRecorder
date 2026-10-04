import Foundation

/// Scrubs stream URLs (which carry provider credentials) out of text that may
/// reach a log line or a `failureReason`, e.g. ffmpeg's stderr.
public enum Redactor {
    public static let placeholder = "<redacted>"

    /// Removes every URL-looking token plus any fragment of `streamURL`
    /// (host, path, query, user, password) that appears on its own.
    public static func redact(_ text: String, streamURL: URL? = nil) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(result.startIndex ..< result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: placeholder)
        }
        if let streamURL {
            for secret in secrets(of: streamURL) {
                result = result.replacingOccurrences(of: secret, with: placeholder)
            }
        }
        return result
    }

    /// Fragments of a URL worth scrubbing, longest first. Very short pieces
    /// are skipped so a 2-character password doesn't shred unrelated text.
    static func secrets(of url: URL) -> [String] {
        var candidates = [url.absoluteString]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let components {
            candidates.append(components.percentEncodedPath)
            candidates.append(components.path)
            if let query = components.percentEncodedQuery { candidates.append(query) }
            if let user = components.user { candidates.append(user) }
            if let password = components.password { candidates.append(password) }
            if let host = components.host {
                candidates.append(host)
                candidates.append(host + components.percentEncodedPath)
                if let port = components.port {
                    candidates.append("\(host):\(port)")
                    candidates.append("\(host):\(port)\(components.percentEncodedPath)")
                }
            }
        }
        return Array(Set(candidates.filter { $0.count >= 4 && $0 != "/" })).sorted { $0.count > $1.count }
    }

    // Any scheme://… run of non-space characters.
    private static let urlPattern = #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s'"<>]+"#
}
