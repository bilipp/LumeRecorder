import AppKit
import Logging
import RecorderCore
import SwiftUI

@main
struct LumeRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.activeRecordings > 0 ? "record.circle.fill" : "record.circle")
                .accessibilityLabel("LumeRecorder")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: ServerController

    override init() {
        let config = RecorderConfig.forApp()
        let level = config.logLevel
        LoggingSystem.bootstrap { label in
            var stderr = StreamLogHandler.standardError(label: label)
            stderr.logLevel = level
            return MultiplexLogHandler([stderr, FileLogHandler(label: label, logLevel: level)])
        }
        controller = ServerController(config: config, logger: Logger(label: "lume-recorder"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        // A DVR has to be running to record: opt in to login launch once, from
        // an installed bundle (`swift run` has no bundle to register).
        let offeredKey = "didEnableLaunchAtLogin"
        if Bundle.main.bundleURL.pathExtension == "app", !UserDefaults.standard.bool(forKey: offeredKey) {
            UserDefaults.standard.set(true, forKey: offeredKey)
            controller.setLaunchAtLogin(true)
        }
    }

    /// Stops ffmpeg before quitting so no orphaned process keeps writing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning else { return .terminateNow }
        Task {
            await controller.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
