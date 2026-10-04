import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// Rotates the pairing code (and logs each new one) until shutdown.
struct PairingRotationService: Service {
    let pairing: PairingManager

    func run() async throws {
        await cancelWhenGracefulShutdown {
            await pairing.runRotationLoop()
        }
    }
}

/// Assembles and runs the whole server.
public enum RecorderServer {
    /// The production application: HTTP + scheduler + pairing rotation (+ Bonjour on macOS).
    public static func makeApplication(services: RecorderServices) -> some ApplicationProtocol {
        let router = RecorderRoutes.makeRouter(services: services)
        var app = Application(
            router: router,
            configuration: .init(
                address: .hostname(services.config.host, port: services.config.port),
                serverName: "LumeRecorder/\(RecorderVersion.current)"
            ),
            logger: services.logger
        )
        app.addServices(services.scheduler, PairingRotationService(pairing: services.pairing))
        if services.config.bonjourEnabled {
            app.addServices(BonjourService(
                name: services.config.serverName,
                port: services.config.port,
                serverID: services.store.identity.id,
                logger: services.logger
            ))
        }
        return app
    }

    /// Builds services with real ffmpeg and runs until SIGINT/SIGTERM.
    public static func run(config: RecorderConfig, logger: Logger) async throws {
        let launcher = FFmpegLauncher(path: config.ffmpegPath)
        if let executable = launcher.executable {
            let caps = launcher.capabilities
            logger.info("Using ffmpeg at \(executable.path) (readrate: \(caps.readRate), burst: \(caps.readRateInitialBurst), catchup: \(caps.readRateCatchup))")
        } else {
            logger.error("ffmpeg not found (FFMPEG_PATH=\(config.ffmpegPath)); recordings will fail until it is installed")
        }
        let services = try RecorderServices(config: config, launcher: launcher, logger: logger)
        logger.notice("LumeRecorder \(RecorderVersion.current) \"\(config.serverName)\" (id \(services.store.identity.id)) listening on \(config.host):\(config.port), data in \(config.dataDirectory.path)")
        // Recover before serving so admission counts are right from the first request.
        await services.scheduler.recover()
        try await makeApplication(services: services).runService()
    }
}
