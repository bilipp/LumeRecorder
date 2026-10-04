import Foundation
@testable import LumeRecorderKit
import Testing

@Suite("Wire coding")
struct CodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try LumeRecorderCoding.makeEncoder().encode(value)
        return try LumeRecorderCoding.makeDecoder().decode(T.self, from: data)
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000.25)

    @Test func recordingRoundTrips() throws {
        let recording = Recording(
            id: UUID(),
            title: "Evening News",
            channelName: "Lume One",
            channelLogoURL: URL(string: "https://example.com/logo.png"),
            programmeDescription: "Headlines",
            sourceRef: "lume:42:abc",
            start: referenceDate,
            end: referenceDate.addingTimeInterval(1800),
            status: .recording,
            failureReason: nil,
            createdAt: referenceDate.addingTimeInterval(-60),
            startedAt: referenceDate,
            finishedAt: nil,
            durationSeconds: 12.5,
            sizeBytes: 1_234_567
        )
        #expect(try roundTrip(recording) == recording)
    }

    @Test func everyDTORoundTrips() throws {
        let info = ServerInfo(id: UUID(), name: "nas", version: "0.1.0", apiVersion: 1)
        #expect(try roundTrip(info) == info)
        #expect(try roundTrip(PairRequest(code: "123456", deviceName: "Apple TV")) == PairRequest(code: "123456", deviceName: "Apple TV"))
        let pair = PairResponse(token: "t", deviceID: UUID(), server: info)
        #expect(try roundTrip(pair) == pair)
        let device = PairedDevice(id: UUID(), name: "iPhone", pairedAt: referenceDate, lastSeenAt: nil)
        #expect(try roundTrip(device) == device)
        let status = ServerStatus(activeRecordings: 1, scheduledRecordings: 2, freeDiskBytes: 3, totalDiskBytes: 4, maxConcurrent: 4)
        #expect(try roundTrip(status) == status)
        let grant = PlaybackGrant(url: URL(string: "http://h:8090/play/x/1/ab/index.m3u8")!, expiresAt: referenceDate)
        #expect(try roundTrip(grant) == grant)
        let create = CreateRecordingRequest(
            streamURL: URL(string: "http://p/live/u/p/1.ts")!,
            title: "T",
            start: referenceDate,
            end: referenceDate.addingTimeInterval(60),
            sourceRef: "ref"
        )
        #expect(try roundTrip(create) == create)
        let error = ErrorResponse(code: "rate_limited", message: "slow down")
        #expect(try roundTrip(error) == error)
    }

    @Test func errorResponseShape() throws {
        let data = try LumeRecorderCoding.makeEncoder().encode(ErrorResponse(code: "unauthorized", message: "nope"))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"error":{"code":"unauthorized","message":"nope"}}"#)
    }

    @Test(arguments: [
        ("scheduled", RecordingStatus.scheduled),
        ("recording", .recording),
        ("completed", .completed),
        ("failed", .failed),
        ("cancelled", .cancelled),
        ("transcoding", .unknown("transcoding")),
    ])
    func statusDecodesAndRoundTrips(raw: String, expected: RecordingStatus) throws {
        let data = Data("\"\(raw)\"".utf8)
        let decoded = try LumeRecorderCoding.makeDecoder().decode(RecordingStatus.self, from: data)
        #expect(decoded == expected)
        let reencoded = try LumeRecorderCoding.makeEncoder().encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "\"\(raw)\"")
    }

    @Test func unknownStatusInsideRecordingDoesNotBreakDecoding() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"x","start":"2026-10-03T18:00:00Z",
         "end":"2026-10-03T19:00:00.5Z","status":"archived","createdAt":"2026-10-03T17:00:00.123Z"}
        """
        let recording = try LumeRecorderCoding.makeDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(recording.status == .unknown("archived"))
        #expect(recording.status.rawValue == "archived")
        #expect(recording.channelName == nil)
        #expect(recording.end.timeIntervalSince(recording.start) == 3600.5)
    }

    @Test func datesEncodeWithFractionalSecondsAndDecodeEitherWay() throws {
        let encoded = LumeRecorderCoding.formatDate(Date(timeIntervalSince1970: 0.5))
        #expect(encoded == "1970-01-01T00:00:00.500Z")
        #expect(LumeRecorderCoding.parseDate("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(LumeRecorderCoding.parseDate("1970-01-01T00:00:00.250Z") == Date(timeIntervalSince1970: 0.25))
        #expect(LumeRecorderCoding.parseDate("1970-01-01T01:00:00+01:00") == Date(timeIntervalSince1970: 0))
        #expect(LumeRecorderCoding.parseDate("yesterday") == nil)
    }
}
