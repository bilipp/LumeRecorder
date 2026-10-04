import Foundation
@testable import RecorderCore
import Testing

@Suite("Pairing")
struct PairingTests {
    let dir = makeTempDirectory()

    @Test func acceptsTheCurrentCodeRepeatedlyWithOrWithoutSpaces() async {
        defer { removeTempDirectory(dir) }
        let pairing = PairingManager(directory: dir)
        let code = await pairing.currentCode().code
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        #expect(await pairing.verify(code) == .accepted)
        // Not consumed: a second device can pair in the same window.
        #expect(await pairing.verify("\(code.prefix(3)) \(code.suffix(3))") == .accepted)
    }

    @Test func rejectsAWrongCode() async {
        defer { removeTempDirectory(dir) }
        let pairing = PairingManager(directory: dir)
        let code = await pairing.currentCode().code
        let wrong = code == "000000" ? "111111" : "000000"
        #expect(await pairing.verify(wrong) == .invalid)
        #expect(await pairing.verify("") == .invalid)
        #expect(await pairing.verify("12345") == .invalid)
    }

    @Test func rateLimitsAfterFiveFailuresPerMinuteEvenForTheRightCode() async {
        defer { removeTempDirectory(dir) }
        let clock = TestClock()
        let pairing = PairingManager(directory: dir, now: clock.provider)
        let code = await pairing.currentCode().code
        let wrong = code == "999999" ? "888888" : "999999"
        for _ in 0 ..< 5 {
            #expect(await pairing.verify(wrong) == .invalid)
        }
        #expect(await pairing.verify(code) == .rateLimited)
        #expect(await pairing.verify(wrong) == .rateLimited)
        clock.advance(by: 61)
        #expect(await pairing.verify(await pairing.currentCode().code) == .accepted)
    }

    @Test func rotatesEveryTenMinutes() async {
        defer { removeTempDirectory(dir) }
        let clock = TestClock()
        let pairing = PairingManager(directory: dir, now: clock.provider)
        let first = await pairing.currentCode()
        #expect(first.expiresAt == clock.now.addingTimeInterval(600))
        clock.advance(by: 599)
        #expect(await pairing.currentCode() == first)
        clock.advance(by: 2)
        let second = await pairing.currentCode()
        #expect(second.expiresAt == clock.now.addingTimeInterval(600))
        if second.code != first.code {
            #expect(await pairing.verify(first.code) == .invalid)
        }
        #expect(await pairing.verify(second.code) == .accepted)
        // The file `lume-recorder pair` reads follows the rotation.
        #expect(PairingCodeFile.read(from: dir)?.code == second.code)
    }

    @Test func codeFileIsReadableAndFormatted() async throws {
        defer { removeTempDirectory(dir) }
        let pairing = PairingManager(directory: dir)
        let code = await pairing.currentCode()
        let file = try #require(PairingCodeFile.read(from: dir))
        #expect(file.code == code.code)
        #expect(abs(file.expiresAt.timeIntervalSince(code.expiresAt)) < 0.01)
        #expect(PairingManager.format("123456") == "123 456")
        let attributes = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(PairingCodeFile.fileName).path)
        #expect((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@Suite("Playback signing")
struct SignerTests {
    let signer = PlaybackSigner(secret: Data(repeating: 7, count: 32))
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func validSignature() {
        let expiry = Int(now.timeIntervalSince1970) + 3600
        let signature = signer.signature(id: id, expiry: expiry)
        #expect(signature.count == 64)
        #expect(signer.verify(id: id, expiry: expiry, signature: signature, now: now) == .valid)
        #expect(signer.verify(id: id, expiry: expiry, signature: signature.uppercased(), now: now) == .valid)
        #expect(signer.path(id: id, expiry: expiry) == "/play/\(id.uuidString.lowercased())/\(expiry)/\(signature)/index.m3u8")
    }

    @Test func expiredSignature() {
        let expiry = Int(now.timeIntervalSince1970) - 1
        #expect(signer.verify(id: id, expiry: expiry, signature: signer.signature(id: id, expiry: expiry), now: now) == .expired)
    }

    @Test func tamperedSignatures() {
        let expiry = Int(now.timeIntervalSince1970) + 3600
        let signature = signer.signature(id: id, expiry: expiry)
        let flipped = String(signature.dropLast()) + (signature.last == "0" ? "1" : "0")
        #expect(signer.verify(id: id, expiry: expiry, signature: flipped, now: now) == .invalid)
        #expect(signer.verify(id: UUID(), expiry: expiry, signature: signature, now: now) == .invalid)
        #expect(signer.verify(id: id, expiry: expiry + 86400, signature: signature, now: now) == .invalid)
        #expect(signer.verify(id: id, expiry: expiry, signature: "", now: now) == .invalid)
        #expect(signer.verify(id: id, expiry: expiry, signature: String(signature.prefix(32)), now: now) == .invalid)
        #expect(signer.verify(id: id, expiry: expiry, signature: String(repeating: "z", count: 64), now: now) == .invalid)
        let otherSecret = PlaybackSigner(secret: Data(repeating: 8, count: 32))
        #expect(otherSecret.verify(id: id, expiry: expiry, signature: signature, now: now) == .invalid)
    }

    @Test(arguments: ["index.m3u8", "a1_00000.ts", "a12_00042.ts", "seg-1.ts"])
    func safeFileNames(name: String) {
        #expect(PlaybackSigner.isSafeMediaFileName(name))
    }

    @Test(arguments: [
        "", ".ts", ".m3u8", "..", "../index.m3u8", "..%2Findex.m3u8", "%2e%2e.ts", "a/b.ts", "a\\b.ts",
        "a.b.ts", "index.M3U8", "index.mp4", "server.json", " index.m3u8", "index.m3u8 ", "a1_00000.ts\u{0}",
        "a1_00000.ts/..", "/etc/passwd", "~root.ts", String(repeating: "a", count: 200) + ".ts",
    ])
    func unsafeFileNames(name: String) {
        #expect(!PlaybackSigner.isSafeMediaFileName(name))
    }
}

@Suite("HLS + redaction helpers")
struct HelperTests {
    @Test func summarizesAndPatchesPlaylists() throws {
        let text = "#EXTM3U\n#EXT-X-DISCONTINUITY\n#EXTINF:6.000000,\na1_00000.ts\n#EXTINF:2.5,\na1_00001.ts\n#EXT-X-ENDLIST\n"
        let summary = HLSPlaylist.summarize(text)
        #expect(summary.segmentCount == 2)
        #expect(summary.durationSeconds == 8.5)
        #expect(summary.hasEndList)
        #expect(!HLSPlaylist.removingEndList(text).contains("ENDLIST"))

        let dir = makeTempDirectory()
        defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("index.m3u8")
        try HLSPlaylist.removingEndList(text).write(to: url, atomically: true, encoding: .utf8)
        #expect(try HLSPlaylist.ensureEndList(at: url))
        #expect(try !HLSPlaylist.ensureEndList(at: url)) // idempotent
        let patched = try String(contentsOf: url, encoding: .utf8)
        #expect(patched.components(separatedBy: "#EXT-X-ENDLIST").count == 2)
        #expect(try !HLSPlaylist.ensureEndList(at: dir.appendingPathComponent("missing.m3u8")))
    }

    @Test func redactsURLsAndCredentialFragments() {
        let url = URL(string: "http://alice:s3cret@iptv.example.com:8080/live/alice/s3cret/1234.ts?token=abcd1234")!
        let text = """
        [http @ 0x1] Opening 'http://iptv.example.com:8080/live/alice/s3cret/1234.ts' for reading
        Failed to resolve hostname iptv.example.com: nodename nor servname provided
        tcp://10.0.0.1:8080 refused; path /live/alice/s3cret/1234.ts; q=token=abcd1234; https://cdn.other/x.m3u8
        """
        let redacted = Redactor.redact(text, streamURL: url)
        for secret in ["s3cret", "alice", "iptv.example.com", "abcd1234", "10.0.0.1", "cdn.other", "://"] {
            #expect(!redacted.contains(secret), "leaked \(secret)")
        }
        #expect(redacted.contains("Failed to resolve hostname"))
    }

    @Test func failureReasonKeepsTheUsefulTail() {
        let url = URL(string: "http://h.example/live/u/p/1.ts")!
        let reason = RecordingScheduler.failureReason(fromStderr: "a\nb\nError opening input file http://h.example/live/u/p/1.ts.\nServer returned 403 Forbidden\n", streamURL: url)
        #expect(reason.hasPrefix("no_segments: "))
        #expect(reason.contains("403 Forbidden"))
        #expect(!reason.contains("h.example"))
        #expect(RecordingScheduler.failureReason(fromStderr: nil, streamURL: url) == "no_segments")
    }

    @Test func ffmpegArgumentsMatchTheContract() {
        let spec = RecordingAttemptSpec(recordingID: UUID(), streamURL: URL(string: "http://h/1.ts")!, outputDirectory: URL(fileURLWithPath: "/tmp"), attempt: 3, maxDuration: 1800)
        let args = FFmpegArguments.make(for: spec, capabilities: .all)
        let joined = args.joined(separator: " ")
        #expect(joined.hasPrefix("-nostdin -hide_banner -loglevel warning -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 30 -rw_timeout 15000000"))
        #expect(joined.contains("-readrate 1 -readrate_initial_burst 10 -readrate_catchup 2 -i http://h/1.ts -t 1800.000"))
        #expect(joined.hasSuffix("-c copy -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type event -hls_flags append_list+independent_segments -hls_segment_filename a3_%05d.ts index.m3u8"))
        let minimal = FFmpegArguments.make(for: spec, capabilities: .none).joined(separator: " ")
        #expect(!minimal.contains("readrate"))
        // A `.ts` source: the HLS-only option would make ffmpeg refuse the input.
        #expect(!spec.hlsInput)
        #expect(!joined.contains("extension_picky"))
    }

    @Test func hlsSourcesRelaxTheExtensionCheckWhenSupported() throws {
        let url = URL(string: "https://cdn.example/tos_ismc/main.M3U8?token=x")!
        let spec = RecordingAttemptSpec(recordingID: UUID(), streamURL: url, outputDirectory: URL(fileURLWithPath: "/tmp"), attempt: 1, maxDuration: 60)
        #expect(spec.hlsInput)

        let args = FFmpegArguments.make(for: spec, capabilities: .all)
        let flag = try #require(args.firstIndex(of: "-extension_picky"))
        let input = try #require(args.firstIndex(of: "-i"))
        #expect(args[flag + 1] == "0")
        #expect(flag < input, "an input option must precede -i")

        var unsupported = FFmpegCapabilities.all
        unsupported.hlsExtensionPicky = false
        #expect(!FFmpegArguments.make(for: spec, capabilities: unsupported).contains("-extension_picky"))
        #expect(!FFmpegArguments.make(for: spec, capabilities: .none).contains("-extension_picky"))
    }

    @Test func hlsInputCanBeForcedEitherWay() {
        let ts = URL(string: "http://h/live/u/p/1.ts")!
        let m3u8 = URL(string: "http://h/live/u/p/1.m3u8")!
        let forced = RecordingAttemptSpec(recordingID: UUID(), streamURL: ts, outputDirectory: URL(fileURLWithPath: "/tmp"), attempt: 2, maxDuration: 60, hlsInput: true)
        #expect(FFmpegArguments.make(for: forced, capabilities: .all).contains("-extension_picky"))
        let disabled = RecordingAttemptSpec(recordingID: UUID(), streamURL: m3u8, outputDirectory: URL(fileURLWithPath: "/tmp"), attempt: 2, maxDuration: 60, hlsInput: false)
        #expect(!FFmpegArguments.make(for: disabled, capabilities: .all).contains("-extension_picky"))
        #expect(FFmpegArguments.looksLikeHLS(URL(string: "http://h/get.php?x=1")!) == false)
        #expect(FFmpegArguments.looksLikeHLS(URL(string: "http://h/list.m3u")!))
    }
}
