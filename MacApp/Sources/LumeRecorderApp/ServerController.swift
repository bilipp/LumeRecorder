import AppKit
import Foundation
import Logging
import LumeRecorderKit
import Observation
import RecorderCore
import ServiceLifecycle
import ServiceManagement

/// Runs RecorderCore in-process and publishes its state to the menu.
@MainActor
@Observable
final class ServerController {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .stopped
    private(set) var pairingCode: PairingCodeFile?
    private(set) var activeRecordings = 0
    private(set) var scheduledRecordings = 0
    private(set) var pairedDevices = 0
    private(set) var keepingAwake = false
    private(set) var launchAtLogin = SMAppService.mainApp.status
    private(set) var launchAtLoginError: String?
    let config: RecorderConfig
    let ffmpegFound: Bool

    @ObservationIgnored private var services: RecorderServices?
    @ObservationIgnored private var group: ServiceGroup?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private let sleepAssertion = SleepAssertion()
    @ObservationIgnored private let logger: Logger

    init(config: RecorderConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        ffmpegFound = FFmpegArguments.resolveExecutable(config.ffmpegPath) != nil
    }

    var isRunning: Bool { runTask != nil }

    var recordingsDirectory: URL { config.dataDirectory.appendingPathComponent("recordings", isDirectory: true) }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil else { return }
        phase = .starting
        stopRequested = false
        let config = config
        let logger = logger
        runTask = Task {
            do {
                // ffmpeg capability detection spawns processes; keep it off the main actor.
                let services = try await Task.detached {
                    try RecorderServer.makeServices(config: config, logger: logger)
                }.value
                await services.scheduler.recover()
                let group = ServiceGroup(
                    services: [RecorderServer.makeApplication(services: services)],
                    gracefulShutdownSignals: [.sigterm, .sigint],
                    logger: logger
                )
                self.services = services
                self.group = group
                guard !stopRequested else {
                    finished(error: nil)
                    return
                }
                phase = .running
                startPolling()
                try await group.run()
                finished(error: nil)
            } catch {
                finished(error: error)
            }
        }
    }

    /// Stops ffmpeg gracefully; running recordings resume on the next start.
    func stop() async {
        guard let runTask else { return }
        stopRequested = true
        await group?.triggerGracefulShutdown()
        await runTask.value
    }

    func restart() async {
        await stop()
        start()
    }

    private func finished(error: (any Error)?) {
        pollTask?.cancel()
        pollTask = nil
        services = nil
        group = nil
        runTask = nil
        pairingCode = nil
        activeRecordings = 0
        scheduledRecordings = 0
        sleepAssertion.release()
        keepingAwake = false
        if let error {
            logger.error("Server stopped: \(error)")
            phase = .failed(String(describing: error))
        } else {
            phase = .stopped
            // SIGTERM/SIGINT ended the service group: quit like the CLI would.
            if !stopRequested { NSApp.terminate(nil) }
        }
    }

    // MARK: State

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        guard let services else { return }
        let active = await services.scheduler.activeCount
        let now = Date()
        let scheduled = await services.store.recordings().count { $0.status == .scheduled && $0.end > now }
        let devices = await services.store.devices().count
        let code = await services.pairing.currentCode()
        guard self.services != nil else { return }
        activeRecordings = active
        scheduledRecordings = scheduled
        pairedDevices = devices
        pairingCode = code
        // A sleeping Mac misses scheduled starts too, so stay awake while any are pending.
        if active > 0 || scheduled > 0 {
            sleepAssertion.hold(reason: "LumeRecorder has recordings in progress or scheduled")
        } else {
            sleepAssertion.release()
        }
        keepingAwake = sleepAssertion.isHeld
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status
    }
}

extension RecorderConfig {
    /// Environment variables still win; otherwise data lives in Application
    /// Support and ffmpeg comes from the bundle, then Homebrew (a GUI app's
    /// PATH doesn't include it).
    static func forApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> RecorderConfig {
        var config = RecorderConfig.fromEnvironment(environment)
        if environment["DATA_DIR"] == nil {
            config.dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LumeRecorder", isDirectory: true)
        }
        if environment["FFMPEG_PATH"] == nil {
            let candidates: [String?] = [
                Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path(percentEncoded: false),
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
            ]
            if let found = candidates.compactMap(\.self).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                config.ffmpegPath = found
            }
        }
        return config
    }
}
