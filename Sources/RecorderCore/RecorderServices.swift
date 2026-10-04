import Foundation
import Logging
import LumeRecorderKit

/// The wired-up object graph shared by the HTTP layer and the services.
public struct RecorderServices: Sendable {
    public let config: RecorderConfig
    public let store: RecorderStore
    public let scheduler: RecordingScheduler
    public let pairing: PairingManager
    public let signer: PlaybackSigner
    public let now: NowProvider
    public let logger: Logger

    public init(
        config: RecorderConfig,
        launcher: any RecordingProcessLauncher,
        disk: any DiskSpaceProviding = FileSystemDiskSpace(),
        now: @escaping NowProvider = { Date() },
        logger: Logger = Logger(label: "lume-recorder"),
        configureScheduler: (inout RecordingScheduler.Options) -> Void = { _ in }
    ) throws {
        self.config = config
        self.now = now
        self.logger = logger
        let store = try RecorderStore(directory: config.dataDirectory, now: now())
        self.store = store
        guard let signer = PlaybackSigner(base64Secret: store.identity.playbackSecret) else {
            throw RecorderError.invalidRequest("server.json holds an invalid playback secret")
        }
        self.signer = signer
        var options = RecordingScheduler.Options(maxConcurrent: config.maxConcurrent, minFreeBytes: config.minFreeBytes)
        configureScheduler(&options)
        scheduler = RecordingScheduler(store: store, launcher: launcher, options: options, disk: disk, now: now, logger: logger)
        pairing = PairingManager(directory: config.dataDirectory, now: now, logger: logger)
    }

    public var serverInfo: ServerInfo {
        ServerInfo(
            id: store.identity.id,
            name: config.serverName,
            version: RecorderVersion.current,
            apiVersion: LumeRecorderAPI.version
        )
    }
}
