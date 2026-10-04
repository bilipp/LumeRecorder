import Foundation
import Logging
import LumeRecorderKit

/// The current pairing code as written to `DATA_DIR/pairing-code.json` for
/// `lume-recorder pair` to read.
public struct PairingCodeFile: Codable, Sendable, Hashable {
    public var code: String
    public var expiresAt: Date

    public static let fileName = "pairing-code.json"

    /// `123456` → `123 456`.
    public var formatted: String {
        PairingManager.format(code)
    }

    public static func read(from directory: URL) -> PairingCodeFile? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LumeRecorderCoding.makeDecoder().decode(PairingCodeFile.self, from: data)
    }
}

/// Owns the rotating 6-digit pairing code and the global failed-attempt limit.
///
/// A correct code does not get consumed — several devices can pair inside one
/// window — but the code still rotates on schedule.
public actor PairingManager {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case invalid
        case rateLimited
    }

    public nonisolated let rotationInterval: TimeInterval
    public nonisolated let maxFailures: Int
    public nonisolated let failureWindow: TimeInterval

    private let directory: URL
    private let now: NowProvider
    private let logger: Logger
    private var code: PairingCodeFile
    private var failures: [Date] = []

    public init(
        directory: URL,
        now: @escaping NowProvider = { Date() },
        rotationInterval: TimeInterval = 600,
        maxFailures: Int = 5,
        failureWindow: TimeInterval = 60,
        logger: Logger = Logger(label: "lume-recorder.pairing")
    ) {
        self.directory = directory
        self.now = now
        self.rotationInterval = rotationInterval
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.logger = logger
        code = PairingCodeFile(code: Self.generateCode(), expiresAt: now().addingTimeInterval(rotationInterval))
        Self.write(code, to: directory, logger: logger)
        Self.announce(code, interval: rotationInterval, logger: logger)
    }

    /// The live code, rotating first if it has expired.
    public func currentCode() -> PairingCodeFile {
        rotateIfExpired()
        return code
    }

    /// Checks a submitted code. While more than `maxFailures` failures sit in
    /// the trailing `failureWindow`, every attempt — right or wrong — is refused.
    public func verify(_ submitted: String) -> Verdict {
        let current = now()
        failures.removeAll { current.timeIntervalSince($0) >= failureWindow }
        guard failures.count < maxFailures else { return .rateLimited }
        rotateIfExpired()
        let normalized = submitted.filter(\.isNumber)
        if Secrets.constantTimeEquals(normalized, code.code) {
            return .accepted
        }
        failures.append(current)
        return .invalid
    }

    /// Rotates on schedule (logging each new code) until cancelled.
    public func runRotationLoop() async {
        while !Task.isCancelled {
            let wait = max(0.5, code.expiresAt.timeIntervalSince(now()))
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return
            }
            rotateIfExpired()
        }
    }

    private func rotateIfExpired() {
        guard now() >= code.expiresAt else { return }
        code = PairingCodeFile(code: Self.generateCode(), expiresAt: now().addingTimeInterval(rotationInterval))
        Self.write(code, to: directory, logger: logger)
        Self.announce(code, interval: rotationInterval, logger: logger)
    }

    // MARK: Helpers

    static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0 ... 999_999, using: &generator)
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    static func format(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private static func announce(_ code: PairingCodeFile, interval: TimeInterval, logger: Logger) {
        let minutes = Int((interval / 60).rounded())
        logger.notice("Pairing code: \(format(code.code)) (valid \(minutes) min)")
    }

    private static func write(_ code: PairingCodeFile, to directory: URL, logger: Logger) {
        do {
            let data = try LumeRecorderCoding.makeEncoder().encode(code)
            try AtomicFile.write(data, to: directory.appendingPathComponent(PairingCodeFile.fileName))
        } catch {
            logger.warning("Couldn't write the pairing code file: \(error)")
        }
    }
}
