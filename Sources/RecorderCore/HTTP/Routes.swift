import Foundation
import HTTPTypes
import Hummingbird
import LumeRecorderKit

/// Per-request context: the authenticated device (if any) plus the shared
/// wire coders so request/response formats match the Kit exactly.
public struct RecorderRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var device: DeviceRecord?

    public init(source: Source) {
        coreContext = .init(source: source)
        device = nil
    }

    public var requestDecoder: JSONDecoder { LumeRecorderCoding.makeDecoder() }
    public var responseEncoder: JSONEncoder { LumeRecorderCoding.makeEncoder() }
    public var maxUploadSize: Int { 256 * 1024 }
}

/// Resolves `Authorization: Bearer <token>` to a paired device or throws 401.
struct BearerAuthMiddleware: RouterMiddleware {
    let services: RecorderServices

    func handle(
        _ request: Request,
        context: RecorderRequestContext,
        next: (Request, RecorderRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization] else { throw APIError.unauthorized }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { throw APIError.unauthorized }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let device = await services.store.device(tokenHash: Secrets.sha256Hex(token)) else {
            throw APIError.unauthorized
        }
        await services.store.touchDevice(device.id, at: services.now())
        var context = context
        context.device = device
        return try await next(request, context)
    }
}

/// Builds the router for the v1 API and the signed playback routes.
public enum RecorderRoutes {
    static let idempotencyHeader = HTTPField.Name(LumeRecorderAPI.idempotencyKeyHeader)!
    static let hostHeader = HTTPField.Name("Host")!
    static let forwardedProtoHeader = HTTPField.Name("X-Forwarded-Proto")!

    public static func makeRouter(services: RecorderServices) -> Router<RecorderRequestContext> {
        let router = Router(context: RecorderRequestContext.self)
        router.add(middleware: ErrorMiddleware())

        let api = router.group("api/v1")
        api.get("info") { _, _ in
            try JSONResponse.make(services.serverInfo)
        }
        api.post("pair") { request, context in
            try await pair(request: request, context: context, services: services)
        }

        let authed = api.group().add(middleware: BearerAuthMiddleware(services: services))
        authed.get("recordings") { _, _ in
            let records = await services.store.recordings()
            return try JSONResponse.make(records.map { publicRecording($0, services: services) })
        }
        authed.post("recordings") { request, context in
            let body = try await request.decode(as: CreateRecordingRequest.self, context: context)
            let key = request.headers[idempotencyHeader]
            let (record, created) = try await services.scheduler.create(body, deviceID: context.device?.id, idempotencyKey: key)
            return try JSONResponse.make(publicRecording(record, services: services), status: created ? .created : .ok)
        }
        authed.post("recordings/:id/stop") { _, context in
            let id = try recordingID(context)
            let record = try await services.scheduler.stop(id)
            return try JSONResponse.make(publicRecording(record, services: services))
        }
        authed.delete("recordings/:id") { _, context in
            try await services.scheduler.delete(recordingID(context))
            return Response(status: .noContent)
        }
        authed.post("recordings/:id/playback") { request, context in
            try await playbackGrant(id: recordingID(context), request: request, services: services)
        }
        authed.get("status") { _, _ in
            try await status(services: services)
        }
        authed.get("devices") { _, _ in
            try await JSONResponse.make(services.store.devices().map(\.publicDevice))
        }
        authed.delete("devices/:id") { _, context in
            guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw APIError.notFound }
            guard try await services.store.removeDevice(id) else { throw APIError.notFound }
            services.logger.info("Device \(id) unpaired")
            return Response(status: .noContent)
        }

        router.get("play/:id/:expiry/:signature/:file") { request, context in
            try await play(request: request, context: context, services: services)
        }
        return router
    }

    // MARK: Handlers

    private static func pair(request: Request, context: RecorderRequestContext, services: RecorderServices) async throws -> Response {
        let body = try await request.decode(as: PairRequest.self, context: context)
        switch await services.pairing.verify(body.code) {
        case .rateLimited:
            throw APIError.rateLimited
        case .invalid:
            services.logger.warning("Rejected a pairing attempt with a wrong code")
            throw APIError.pairingInvalid
        case .accepted:
            break
        }
        var name = body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Unnamed device" }
        if name.count > 100 { name = String(name.prefix(100)) }
        let token = Secrets.makeToken()
        let current = services.now()
        let device = DeviceRecord(id: UUID(), name: name, tokenHash: Secrets.sha256Hex(token), pairedAt: current, lastSeenAt: current)
        try await services.store.addDevice(device)
        services.logger.notice("Paired device \"\(name)\" (\(device.id))")
        return try JSONResponse.make(PairResponse(token: token, deviceID: device.id, server: services.serverInfo))
    }

    private static func playbackGrant(id: UUID, request: Request, services: RecorderServices) async throws -> Response {
        guard let record = await services.store.recording(id) else { throw APIError.notFound }
        let playlist = services.store.mediaDirectory(for: id).appendingPathComponent(PlaybackSigner.playlistName)
        guard record.status != .scheduled, FileManager.default.fileExists(atPath: playlist.path) else {
            throw RecorderError.notPlayable
        }
        let expiresAt = services.now().addingTimeInterval(services.config.playbackGrantLifetime)
        let expiry = Int(expiresAt.timeIntervalSince1970)
        let path = services.signer.path(id: id, expiry: expiry)
        guard let url = URL(string: baseURL(for: request, config: services.config) + path) else {
            throw APIError.invalidRequest("Couldn't build a playback URL from the Host header.")
        }
        return try JSONResponse.make(PlaybackGrant(url: url, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry))))
    }

    private static func status(services: RecorderServices) async throws -> Response {
        let records = await services.store.recordings()
        let space = await services.scheduler.diskSpace()
        return try JSONResponse.make(ServerStatus(
            activeRecordings: records.count { $0.status == .recording },
            scheduledRecordings: records.count { $0.status == .scheduled },
            freeDiskBytes: space?.freeBytes ?? 0,
            totalDiskBytes: space?.totalBytes ?? 0,
            maxConcurrent: services.config.maxConcurrent
        ))
    }

    private static func play(request: Request, context: RecorderRequestContext, services: RecorderServices) async throws -> Response {
        guard let rawID = context.parameters.get("id"), let id = UUID(uuidString: rawID),
              let rawExpiry = context.parameters.get("expiry"), let expiry = Int(rawExpiry),
              let signature = context.parameters.get("signature"),
              let file = context.parameters.get("file")
        else { throw APIError.notFound }

        switch services.signer.verify(id: id, expiry: expiry, signature: signature, now: services.now()) {
        case .valid: break
        case .expired, .invalid: throw APIError.forbidden
        }
        guard PlaybackSigner.isSafeMediaFileName(file),
              let record = await services.store.recording(id)
        else { throw APIError.notFound }

        let directory = services.store.mediaDirectory(for: id).standardizedFileURL
        let fileURL = directory.appendingPathComponent(file).standardizedFileURL
        guard fileURL.deletingLastPathComponent().path == directory.path,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { throw APIError.notFound }

        var headers = HTTPFields()
        if file.hasSuffix(".m3u8") {
            guard let data = FileManager.default.contents(atPath: fileURL.path),
                  var text = String(data: data, encoding: .utf8)
            else { throw APIError.notFound }
            if record.status == .recording {
                text = HLSPlaylist.removingEndList(text)
            }
            headers[.contentType] = "application/vnd.apple.mpegurl"
            headers[.cacheControl] = "no-cache"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
        }
        headers[.contentType] = "video/mp2t"
        headers[.cacheControl] = "private, max-age=3600"
        let body = try await FileIO(threadPool: .singleton).loadFile(path: fileURL.path, context: context)
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: Helpers

    private static func recordingID(_ context: RecorderRequestContext) throws -> UUID {
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw APIError.notFound }
        return id
    }

    /// Live recordings report stats read from disk; finished ones use the cache.
    static func publicRecording(_ record: RecordingRecord, services: RecorderServices) -> Recording {
        guard record.status == .recording else { return record.publicRecording() }
        return record.publicRecording(media: MediaInspector.stats(in: services.store.mediaDirectory(for: record.id)))
    }

    /// `scheme://host[:port]` the client used, so the link is reachable from
    /// where the request came from. Falls back to `PUBLIC_URL`, then localhost.
    static func baseURL(for request: Request, config: RecorderConfig) -> String {
        let authority = request.head.authority ?? request.headers[hostHeader]
        if let authority, !authority.isEmpty, !authority.contains(where: { $0 == "/" || $0 == "@" || $0.isWhitespace }) {
            let proto = request.headers[forwardedProtoHeader]?
                .split(separator: ",").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            let scheme = proto == "https" ? "https" : "http"
            return "\(scheme)://\(authority)"
        }
        if var publicURL = config.publicURL?.absoluteString {
            while publicURL.hasSuffix("/") { publicURL.removeLast() }
            return publicURL
        }
        return "http://127.0.0.1:\(config.port)"
    }
}
