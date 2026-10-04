import Foundation

/// The single source of truth for the wire format. Both the server and the
/// client build their coders here, so date and key formats cannot drift.
///
/// Dates are ISO-8601 in UTC with fractional seconds on encode
/// (`2026-10-03T18:30:00.000Z`); decoding accepts them with or without
/// fractional seconds.
public enum LumeRecorderCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date, got \(string)"
                )
            }
            return date
        }
        return decoder
    }

    /// Formats a date the way the API does (ISO-8601, UTC, milliseconds).
    public static func formatDate(_ date: Date) -> String {
        date.formatted(withFractionalSeconds)
    }

    /// Parses an ISO-8601 timestamp with or without fractional seconds.
    public static func parseDate(_ string: String) -> Date? {
        if let date = try? withFractionalSeconds.parse(string) { return date }
        return try? withoutFractionalSeconds.parse(string)
    }

    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle()
}
