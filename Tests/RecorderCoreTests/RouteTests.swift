import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LumeRecorderKit
@testable import RecorderCore
import Testing

/// Spins up the real router over fakes (no ffmpeg, no network).
struct APIHarness {
    let dir: URL
    let launcher: FakeLauncher
    let services: RecorderServices

    init(maxConcurrent: Int = 4, disk: FakeDisk = FakeDisk(), minFreeGB: Double = 0, launcher: FakeLauncher = FakeLauncher()) throws {
        dir = makeTempDirectory()
        self.launcher = launcher
        var config = RecorderConfig(dataDirectory: dir, maxConcurrent: maxConcurrent, minFreeGB: minFreeGB, serverName: "test-recorder", bonjourEnabled: false)
        config.port = 8090
        services = try RecorderServices(config: config, launcher: launcher, disk: disk, configureScheduler: { options in
            options = fastOptions(maxConcurrent: maxConcurrent, minFreeBytes: config.minFreeBytes)
        })
    }

    func run(_ body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        defer { removeTempDirectory(dir) }
        await services.scheduler.recover()
        let app = Application(router: RecorderRoutes.makeRouter(services: services))
        try await app.test(.router, body)
        await services.scheduler.shutdown()
    }

    func pair(_ client: any TestClientProtocol, name: String = "Apple TV") async throws -> PairResponse {
        let code = await services.pairing.currentCode().code
        let response = try await client.execute(uri: "/api/v1/pair", method: .post, headers: json, body: Self.body(PairRequest(code: code, deviceName: name)))
        #expect(response.status == .ok)
        return try Self.decode(PairResponse.self, response)
    }

    let json: HTTPFields = [.contentType: "application/json"]

    func auth(_ token: String, extra: HTTPFields = [:]) -> HTTPFields {
        var fields: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]
        fields.append(contentsOf: extra)
        return fields
    }

    static func body(_ value: some Encodable) -> ByteBuffer {
        ByteBuffer(bytes: try! LumeRecorderCoding.makeEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try LumeRecorderCoding.makeDecoder().decode(T.self, from: Data(response.body.readableBytesView))
    }

    static func errorCode(_ response: TestResponse) -> String? {
        try? decode(ErrorResponse.self, response).error.code
    }

    static func text(_ response: TestResponse) -> String {
        String(decoding: response.body.readableBytesView, as: UTF8.self)
    }

    func createRequest(start: TimeInterval, end: TimeInterval, title: String = "Show") -> CreateRecordingRequest {
        let now = Date()
        return CreateRecordingRequest(
            streamURL: URL(string: "http://user:pass@provider.example/live/user/pass/7.ts")!,
            title: title,
            channelName: "Lume One",
            start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(end),
            sourceRef: "ref-\(title)"
        )
    }
}

@Suite("HTTP API")
struct RouteTests {
    @Test func infoIsPublic() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let response = try await client.execute(uri: "/api/v1/info", method: .get)
            #expect(response.status == .ok)
            let info = try APIHarness.decode(ServerInfo.self, response)
            #expect(info.apiVersion == 1)
            #expect(info.name == "test-recorder")
            #expect(info.version == RecorderVersion.current)
            #expect(info.id == harness.services.store.identity.id)
        }
    }

    @Test func errorsUseTheJSONShape() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let missing = try await client.execute(uri: "/api/v1/nope", method: .get)
            #expect(missing.status == .notFound)
            #expect(APIHarness.errorCode(missing) == "not_found")

            let noToken = try await client.execute(uri: "/api/v1/recordings", method: .get)
            #expect(noToken.status == .unauthorized)
            #expect(APIHarness.errorCode(noToken) == "unauthorized")

            let badToken = try await client.execute(uri: "/api/v1/status", method: .get, headers: harness.auth("forged"))
            #expect(badToken.status == .unauthorized)

            let basic = try await client.execute(uri: "/api/v1/status", method: .get, headers: [.authorization: "Basic Zm9vOmJhcg=="])
            #expect(basic.status == .unauthorized)
        }
    }

    @Test func pairingFlowAndRateLimit() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let code = await harness.services.pairing.currentCode().code
            let wrong = code == "000000" ? "111111" : "000000"
            let rejected = try await client.execute(uri: "/api/v1/pair", method: .post, headers: harness.json, body: APIHarness.body(PairRequest(code: wrong, deviceName: "x")))
            #expect(rejected.status == .unauthorized)
            #expect(APIHarness.errorCode(rejected) == "pairing_invalid")

            let paired = try await harness.pair(client, name: "Living Room")
            #expect(paired.server.id == harness.services.store.identity.id)
            #expect(paired.token.count >= 40)

            // The token is stored only as a hash.
            let devicesFile = try String(contentsOf: harness.dir.appendingPathComponent("devices.json"), encoding: .utf8)
            #expect(!devicesFile.contains(paired.token))
            #expect(devicesFile.contains(Secrets.sha256Hex(paired.token)))

            let authed = try await client.execute(uri: "/api/v1/devices", method: .get, headers: harness.auth(paired.token))
            #expect(authed.status == .ok)
            #expect(try APIHarness.decode([PairedDevice].self, authed).map(\.name) == ["Living Room"])

            for _ in 0 ..< 4 {
                _ = try await client.execute(uri: "/api/v1/pair", method: .post, headers: harness.json, body: APIHarness.body(PairRequest(code: wrong, deviceName: "x")))
            }
            let limited = try await client.execute(uri: "/api/v1/pair", method: .post, headers: harness.json, body: APIHarness.body(PairRequest(code: code, deviceName: "x")))
            #expect(limited.status == .tooManyRequests)
            #expect(APIHarness.errorCode(limited) == "rate_limited")
        }
    }

    @Test func createListIdempotencyAndValidation() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token
            let idem: HTTPFields = [HTTPField.Name("Idempotency-Key")!: "abc-123"]

            let early = harness.createRequest(start: 3600, end: 7200, title: "Early")
            let first = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: harness.auth(token, extra: idem), body: APIHarness.body(early))
            #expect(first.status == .created)
            let created = try APIHarness.decode(Recording.self, first)
            #expect(created.status == .scheduled)
            #expect(created.sourceRef == "ref-Early")
            #expect(!APIHarness.text(first).contains("provider.example"))

            let replay = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: harness.auth(token, extra: idem), body: APIHarness.body(early))
            #expect(replay.status == .ok)
            #expect(try APIHarness.decode(Recording.self, replay).id == created.id)

            let later = harness.createRequest(start: 7200, end: 9000, title: "Later")
            _ = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: harness.auth(token), body: APIHarness.body(later))

            let list = try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(token))
            let recordings = try APIHarness.decode([Recording].self, list)
            #expect(recordings.map(\.title) == ["Later", "Early"])
            #expect(!APIHarness.text(list).contains("streamURL"))
            #expect(!APIHarness.text(list).contains("pass"))

            var invalid = harness.createRequest(start: 10, end: 20)
            invalid.streamURL = URL(string: "rtmp://provider.example/live")!
            let rejected = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: harness.auth(token), body: APIHarness.body(invalid))
            #expect(rejected.status == .badRequest)
            #expect(APIHarness.errorCode(rejected) == "invalid_request")

            let garbage = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: harness.auth(token), body: ByteBuffer(string: "{\"title\":1}"))
            #expect(garbage.status == .badRequest)
            #expect(APIHarness.errorCode(garbage) == "invalid_request")
        }
    }

    @Test func playbackGrantServesSignedHLS() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let token = try await harness.pair(client).token

            let scheduled = try APIHarness.decode(Recording.self, try await client.execute(
                uri: "/api/v1/recordings", method: .post, headers: harness.auth(token), body: APIHarness.body(harness.createRequest(start: 600, end: 1200))
            ))
            let notYet = try await client.execute(uri: "/api/v1/recordings/\(scheduled.id)/playback", method: .post, headers: harness.auth(token))
            #expect(notYet.status == .conflict)
            #expect(APIHarness.errorCode(notYet) == "not_playable")

            let live = try APIHarness.decode(Recording.self, try await client.execute(
                uri: "/api/v1/recordings", method: .post, headers: harness.auth(token), body: APIHarness.body(harness.createRequest(start: 0, end: 60))
            ))
            #expect(live.status == .recording)
            let playlistPath = harness.services.store.mediaDirectory(for: live.id).appendingPathComponent("index.m3u8").path
            #expect(await eventually { FileManager.default.fileExists(atPath: playlistPath) })

            // The router test client always sends authority "localhost"; the
            // link is built from it (the e2e run covers a real Host header).
            var grantHeaders = harness.auth(token)
            grantHeaders[HTTPField.Name("X-Forwarded-Proto")!] = "https"
            let grantResponse = try await client.execute(uri: "/api/v1/recordings/\(live.id)/playback", method: .post, headers: grantHeaders)
            #expect(grantResponse.status == .ok)
            let grant = try APIHarness.decode(PlaybackGrant.self, grantResponse)
            #expect(grant.url.absoluteString.hasPrefix("https://localhost/play/\(live.id.uuidString.lowercased())/"))
            #expect(grant.url.lastPathComponent == "index.m3u8")
            #expect(grant.url.query == nil)
            #expect(abs(grant.expiresAt.timeIntervalSinceNow - 12 * 3600) < 5)

            // In-progress playlist: served without ENDLIST, segment URIs relative.
            let playlist = try await client.execute(uri: grant.url.path, method: .get)
            #expect(playlist.status == .ok)
            #expect(playlist.headers[.contentType] == "application/vnd.apple.mpegurl")
            let text = APIHarness.text(playlist)
            #expect(text.contains("a1_00000.ts"))
            #expect(!text.contains("#EXT-X-ENDLIST"))

            // Segments inherit the signed path prefix.
            let segmentPath = grant.url.deletingLastPathComponent().appendingPathComponent("a1_00000.ts").path
            let segment = try await client.execute(uri: segmentPath, method: .get)
            #expect(segment.status == .ok)
            #expect(segment.headers[.contentType] == "video/mp2t")
            #expect(segment.body.readableBytes == 1880)

            // Tampered, expired and traversal attempts.
            let parts = grant.url.path.split(separator: "/").map(String.init) // play, id, expiry, sig, file
            let signature = parts[3]
            let badSig = String(signature.dropLast()) + (signature.last == "a" ? "b" : "a")
            let tampered = try await client.execute(uri: "/play/\(parts[1])/\(parts[2])/\(badSig)/index.m3u8", method: .get)
            #expect(tampered.status == .forbidden)
            let forgedExpiry = try await client.execute(uri: "/play/\(parts[1])/\(Int(parts[2])! + 1)/\(signature)/index.m3u8", method: .get)
            #expect(forgedExpiry.status == .forbidden)
            let past = Int(Date().timeIntervalSince1970) - 10
            let expired = try await client.execute(uri: harness.services.signer.path(id: live.id, expiry: past), method: .get)
            #expect(expired.status == .forbidden)
            let otherRecording = try await client.execute(uri: "/play/\(scheduled.id.uuidString.lowercased())/\(parts[2])/\(signature)/index.m3u8", method: .get)
            #expect(otherRecording.status == .forbidden)

            let prefix = "/play/\(parts[1])/\(parts[2])/\(signature)"
            for attack in ["..%2F..%2Fserver.json", "..%2F..%2F..%2Fserver.json", "%2e%2e%2fserver.json", "../../server.json", "..", "server.json", "index.m3u8%00.ts", "..%5C..%5Cserver.json"] {
                let response = try await client.execute(uri: "\(prefix)/\(attack)", method: .get)
                #expect(response.status != .ok, "\(attack) was served")
                #expect(!APIHarness.text(response).contains(harness.services.store.identity.playbackSecret))
            }

            // After stopping, the playlist carries ENDLIST.
            let stopped = try await client.execute(uri: "/api/v1/recordings/\(live.id)/stop", method: .post, headers: harness.auth(token))
            #expect(try APIHarness.decode(Recording.self, stopped).status == .completed)
            let finalPlaylist = try await client.execute(uri: grant.url.path, method: .get)
            #expect(APIHarness.text(finalPlaylist).contains("#EXT-X-ENDLIST"))
        }
    }

    @Test func stopDeleteStatusAndUnpair() async throws {
        let harness = try APIHarness()
        try await harness.run { client in
            let me = try await harness.pair(client, name: "Phone")
            let other = try await harness.pair(client, name: "TV")

            let scheduled = try APIHarness.decode(Recording.self, try await client.execute(
                uri: "/api/v1/recordings", method: .post, headers: harness.auth(me.token), body: APIHarness.body(harness.createRequest(start: 600, end: 1200))
            ))
            let live = try APIHarness.decode(Recording.self, try await client.execute(
                uri: "/api/v1/recordings", method: .post, headers: harness.auth(me.token), body: APIHarness.body(harness.createRequest(start: -1, end: 60))
            ))

            let status = try APIHarness.decode(ServerStatus.self, try await client.execute(uri: "/api/v1/status", method: .get, headers: harness.auth(me.token)))
            #expect(status.activeRecordings == 1)
            #expect(status.scheduledRecordings == 1)
            #expect(status.maxConcurrent == 4)
            #expect(status.freeDiskBytes == 500_000_000_000)
            #expect(status.totalDiskBytes == 1_000_000_000_000)

            let cancelled = try await client.execute(uri: "/api/v1/recordings/\(scheduled.id)/stop", method: .post, headers: harness.auth(me.token))
            #expect(try APIHarness.decode(Recording.self, cancelled).status == .cancelled)

            let deleted = try await client.execute(uri: "/api/v1/recordings/\(live.id)", method: .delete, headers: harness.auth(other.token))
            #expect(deleted.status == .noContent)
            let again = try await client.execute(uri: "/api/v1/recordings/\(live.id)", method: .delete, headers: harness.auth(other.token))
            #expect(again.status == .notFound)
            let unknownStop = try await client.execute(uri: "/api/v1/recordings/\(UUID())/stop", method: .post, headers: harness.auth(me.token))
            #expect(unknownStop.status == .notFound)

            let remaining = try APIHarness.decode([Recording].self, try await client.execute(uri: "/api/v1/recordings", method: .get, headers: harness.auth(me.token)))
            #expect(remaining.map(\.id) == [scheduled.id])

            // Unpair the other device, then myself.
            #expect(try await client.execute(uri: "/api/v1/devices/\(other.deviceID)", method: .delete, headers: harness.auth(me.token)).status == .noContent)
            #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: harness.auth(other.token)).status == .unauthorized)
            #expect(try await client.execute(uri: "/api/v1/devices/\(UUID())", method: .delete, headers: harness.auth(me.token)).status == .notFound)
            #expect(try await client.execute(uri: "/api/v1/devices/\(me.deviceID)", method: .delete, headers: harness.auth(me.token)).status == .noContent)
            #expect(try await client.execute(uri: "/api/v1/status", method: .get, headers: harness.auth(me.token)).status == .unauthorized)
        }
    }

    @Test func admissionErrorsMapTo409And507() async throws {
        let full = try APIHarness(maxConcurrent: 1)
        try await full.run { client in
            let token = try await full.pair(client).token
            let first = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: full.auth(token), body: APIHarness.body(full.createRequest(start: 0, end: 60)))
            #expect(first.status == .created)
            let second = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: full.auth(token), body: APIHarness.body(full.createRequest(start: 0, end: 60)))
            #expect(second.status == .conflict)
            #expect(APIHarness.errorCode(second) == "concurrency_limit")
        }

        let lowDisk = try APIHarness(disk: FakeDisk(freeBytes: 10), minFreeGB: 2)
        try await lowDisk.run { client in
            let token = try await lowDisk.pair(client).token
            let response = try await client.execute(uri: "/api/v1/recordings", method: .post, headers: lowDisk.auth(token), body: APIHarness.body(lowDisk.createRequest(start: 0, end: 60)))
            #expect(response.status.code == 507)
            #expect(APIHarness.errorCode(response) == "insufficient_storage")
        }
    }
}
