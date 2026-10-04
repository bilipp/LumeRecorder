import Crypto
import Foundation

/// Signs and verifies playback paths of the form
/// `/play/{id}/{expiryUnix}/{hmacHex}/{file}`.
///
/// The signature lives in the *path* on purpose: HLS players resolve the
/// relative segment URIs in `index.m3u8` (`a1_00000.ts`) against the playlist
/// URL, so every segment request inherits the signed prefix. A query-string
/// signature would be dropped on those requests.
public struct PlaybackSigner: Sendable {
    public enum Verdict: Equatable, Sendable {
        case valid
        case expired
        case invalid
    }

    private let key: SymmetricKey

    public init(secret: Data) {
        key = SymmetricKey(data: secret)
    }

    public init?(base64Secret: String) {
        guard let data = Data(base64Encoded: base64Secret), data.count >= 16 else { return nil }
        self.init(secret: data)
    }

    public static let playlistName = "index.m3u8"

    /// Lowercase hex HMAC-SHA256 over `"{id}:{expiry}"` (id lowercased).
    public func signature(id: UUID, expiry: Int) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(Self.message(id: id, expiry: expiry).utf8), using: key)
        return Secrets.hex(mac)
    }

    /// Path (no host) of `file` inside the signed prefix.
    public func path(id: UUID, expiry: Int, file: String = PlaybackSigner.playlistName) -> String {
        "/play/\(id.uuidString.lowercased())/\(expiry)/\(signature(id: id, expiry: expiry))/\(file)"
    }

    public func verify(id: UUID, expiry: Int, signature: String, now: Date) -> Verdict {
        guard let bytes = Secrets.bytes(fromHex: signature.lowercased()), bytes.count == SHA256.byteCount,
              HMAC<SHA256>.isValidAuthenticationCode(
                  bytes,
                  authenticating: Data(Self.message(id: id, expiry: expiry).utf8),
                  using: key
              )
        else { return .invalid }
        return Double(expiry) > now.timeIntervalSince1970 ? .valid : .expired
    }

    /// Only flat `[A-Za-z0-9_-]+.m3u8|.ts` names are servable: no separators,
    /// no dots besides the extension, nothing that can escape the directory.
    public static func isSafeMediaFileName(_ name: String) -> Bool {
        guard name.count <= 96 else { return false }
        let stem: Substring
        if name.hasSuffix(".m3u8") {
            stem = name.dropLast(5)
        } else if name.hasSuffix(".ts") {
            stem = name.dropLast(3)
        } else {
            return false
        }
        guard !stem.isEmpty else { return false }
        return stem.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
        }
    }

    private static func message(id: UUID, expiry: Int) -> String {
        "\(id.uuidString.lowercased()):\(expiry)"
    }
}
