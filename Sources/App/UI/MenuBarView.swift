// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import AppKit
import SnapHaulKit

/// Primary interface — menu bar popover showing device status,
/// transfer progress, and quick actions.
struct MenuBarView: View {

    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection
            Divider()
            actionSection
            Divider()
            progressSection
            Divider()
            navigationSection
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Device Status

    @ViewBuilder
    private var deviceSection: some View {
        if let device = appState.deviceState {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.headline)
                    Text(connectionDescription(device))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                connectionIndicator(device.connectionStatus)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector.slash")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No device connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        if appState.deviceState != nil {            if appState.isTransferring {
                HStack {
                    Button { appState.pauseTransfer() } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    Button { appState.resumeTransfer() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    Button(role: .destructive) { appState.stopTransfer() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Primary action — browse and pick files
                    Button {
                        openBrowserWindow()
                    } label: {
                        Label("Browse Device", systemImage: "folder.badge.questionmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Browse any folder · select files · copy either direction")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Quick-start from saved profiles (if any)
                    if !appState.profiles.isEmpty {
                        Divider()
                        ForEach(appState.profiles.prefix(3)) { profile in
                            Button {
                                appState.startIngest(profile: profile)
                            } label: {
                            HStack {
                                    Image(systemName: "arrow.down.doc")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text(profile.name)
                                        .font(.caption)
                                    Spacer()
                                    if profile.autoTrigger {
                                        Text("Auto")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            // No device connected — show a hint
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect an Android device via USB to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Set your phone to File Transfer (MTP) mode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        if let progress = appState.transferProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(progress.completedFiles) / \(progress.totalFiles) files")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Text(progress.formattedSpeed)
                        .font(.caption)
                        .monospacedDigit()
                }
                ProgressView(value: progress.overallProgress)
                    .progressViewStyle(.linear)
                if let eta = progress.estimatedSecondsRemaining {
                    Text("ETA: \(formatETA(eta))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !progress.errors.isEmpty {
                    Text("\(progress.errors.count) error(s)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } else if let report = appState.lastReport {
            // Show last ingest summary
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Last ingest: \(report.successfulFiles) files")
                        .font(.caption)
                    Spacer()
                    Text(report.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.failedFiles > 0 {
                    Text("\(report.failedFiles) failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Text("No active transfer")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Navigation

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.deviceState != nil {
                Button {
                    openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)
            }

            SettingsLink {
                Label("Preferences…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Divider()

            Button("Quit SnapHaul") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Open in Finder

    private func openInFinder() {
        // Priority 1: Open the last ingest report's destination
        if let report = appState.lastReport {
            let destPath = appState.profiles
                .first(where: { $0.name == report.profileName })?
                .destinationPath
            if let path = destPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
        }

        // Priority 2: Open the first profile's destination
        if let firstProfile = appState.profiles.first {
            let url = URL(fileURLWithPath: firstProfile.destinationPath)
            // Create the directory if it doesn't exist yet
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(url)
            return
        }

        // Priority 3: Open ~/Pictures as fallback
        let pictures = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        NSWorkspace.shared.open(pictures)
    }

    // MARK: - Helpers

    private func connectionDescription(_ device: DeviceState) -> String {
        var parts: [String] = []
        if let speed = device.usbSpeedDescription {
            parts.append(speed)
        }
        if let engine = device.engineType {
            parts.append(engine.rawValue.uppercased())
        }
        return parts.isEmpty ? "Connected" : "Connected via " + parts.joined(separator: " · ")
    }

    private func connectionIndicator(_ status: ConnectionStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected, .transferring: .green
        case .connecting: .yellow
        case .error: .red
        case .disconnected: .gray
        }
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }

    /// Open the device browser as a standalone window.
    ///
    /// Opens the main app window which has the full file manager UI.
    private func openBrowserWindow() {
        // Bring the main window to front. SwiftUI's Window scene handles creation.
        NSApp.activate(ignoringOtherApps: true)
        // Open the "main" window by its ID
        if let window = NSApp.windows.first(where: { $0.title.contains("SnapHaul") && !$0.title.contains("Settings") }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // If no window exists yet, the Window scene will create one
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
