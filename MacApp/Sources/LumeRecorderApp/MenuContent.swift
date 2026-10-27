import AppKit
import RecorderCore
import ServiceManagement
import SwiftUI

/// The menu-bar window: status, pairing code, settings and actions.
struct MenuContent: View {
    let controller: ServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch controller.phase {
            case .running:
                pairing
                activity
            case .starting:
                Text("Starting…").foregroundStyle(.secondary)
            case .stopped:
                Text("The recorder is stopped.").foregroundStyle(.secondary)
            case let .failed(message):
                Label("The recorder couldn't start.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !controller.ffmpegFound { ffmpegMissing }
            Divider()
            settings
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { controller.refreshLaunchAtLogin() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("LumeRecorder").font(.headline)
                Text("\(controller.config.serverName) · port \(String(controller.config.port))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(RecorderVersion.current).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    @ViewBuilder private var pairing: some View {
        if let code = controller.pairingCode {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                Text(code.formatted)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("In Lume, add this recorder and enter the code. A new code in \(Text(timerInterval: Date.now ... max(Date.now, code.expiresAt)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(recordingSummary, systemImage: controller.activeRecordings > 0 ? "record.circle.fill" : "calendar")
            Label(deviceSummary, systemImage: "appletv")
            if controller.keepingAwake {
                Label("Keeping this Mac awake", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var recordingSummary: String {
        switch (controller.activeRecordings, controller.scheduledRecordings) {
        case (0, 0): "No recordings scheduled"
        case let (active, 0): "Recording \(active) now"
        case let (0, scheduled): "\(scheduled) scheduled"
        case let (active, scheduled): "Recording \(active) now · \(scheduled) scheduled"
        }
    }

    private var deviceSummary: String {
        controller.pairedDevices == 1 ? "1 paired device" : "\(controller.pairedDevices) paired devices"
    }

    private var ffmpegMissing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("ffmpeg not found", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("LumeRecorder can't find the ffmpeg it ships with, so recordings fail. Download LumeRecorder again and replace the app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var settings: some View {
        Toggle("Open at Login", isOn: Binding(
            get: { controller.launchAtLogin == .enabled },
            set: { controller.setLaunchAtLogin($0) }
        ))
        if controller.launchAtLogin == .requiresApproval {
            Button("Allow in Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.link)
        }
        if let error = controller.launchAtLoginError {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Show Recordings in Finder") { showRecordings() }
            Button("Open Log") { NSWorkspace.shared.open(FileLogHandler.fileURL) }
            Button(controller.isRunning ? "Restart Recorder" : "Start Recorder") {
                Task { await controller.restart() }
            }
            Button("Quit LumeRecorder") { quit() }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }

    private func showRecordings() {
        let directory = controller.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func quit() {
        if controller.activeRecordings > 0 {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Quit while recording?"
            alert.informativeText = "Recordings in progress stop now and continue when LumeRecorder opens again. Anything aired in between is missing."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }
}
