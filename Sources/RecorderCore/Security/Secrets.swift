import Crypto
import Foundation

/// Random tokens, hashing and constant-time comparison.
enum Secrets {
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// A 256-bit bearer token, base64url without padding.
    static func makeToken() -> String {
        Data(randomBytes(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 — the only form in which tokens are stored.
    static func sha256Hex(_ string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    /// Compares without short-circuiting on the first differing byte.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0 ..< max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}
