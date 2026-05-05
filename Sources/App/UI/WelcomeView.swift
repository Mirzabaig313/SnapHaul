// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import AppKit
import SnapHaulKit

/// First-run onboarding wizard.
///
/// Guides new users through:
/// 1. Welcome — what SnapHaul does
/// 2. Connect device — how to set up USB file transfer
/// 3. ADB setup (optional) — for faster transfers
/// 4. Create first profile — destination folder + basic settings
///
/// Shown once on first launch. The user can skip at any step.
/// Completion is tracked via `UserDefaults("hasCompletedOnboarding")`.
struct WelcomeView: View {

    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var currentStep: OnboardingStep = .welcome
    @State private var adbDetected = false

    // Profile creation state
    @State private var profileName = "My Photos"
    @State private var destinationPath = ""
    @State private var autoTrigger = true
    @State private var checksumVerification = true

    private enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case connectDevice = 1
        case adbSetup = 2
        case createProfile = 3
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation footer
            footer
        }
        .frame(width: 600, height: 560)
        .onAppear {
            detectADB()
            setDefaultDestination()
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .connectDevice:
            connectDeviceStep
        case .adbSetup:
            adbSetupStep
        case .createProfile:
            createProfileStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cable.connector")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            Text("Welcome to SnapHaul")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Transfer photos and videos from your Android device to your Mac — fast, organized, and verified.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "bolt.fill",
                    color: .yellow,
                    title: "Fast transfers",
                    subtitle: "USB 3.0 speeds via MTP or ADB"
                )
                featureRow(
                    icon: "folder.badge.gearshape",
                    color: .blue,
                    title: "Auto-organize",
                    subtitle: "Sort by date, camera, or custom templates"
                )
                featureRow(
                    icon: "checkmark.shield.fill",
                    color: .green,
                    title: "Verified copies",
                    subtitle: "SHA-256 checksums ensure nothing is corrupted"
                )
                featureRow(
                    icon: "bell.badge.fill",
                    color: .orange,
                    title: "Plug and go",
                    subtitle: "Auto-start ingest when your device connects"
                )
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(32)
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 2: Connect Device

    private var connectDeviceStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            Text("Connect Your Device")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 16) {
                instructionRow(
                    number: 1,
                    text: "Plug your Android phone into your Mac with a USB cable"
                )
                instructionRow(
                    number: 2,
                    text: "On your phone, pull down the notification shade"
                )
                instructionRow(
                    number: 3,
                    text: "Tap the USB notification and select **File Transfer (MTP)**"
                )
            }
            .frame(maxWidth: 400)

            if appState.deviceState != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("Device connected!")
                            .font(.headline)
                            .foregroundStyle(.green)
                        if let name = appState.deviceState?.displayName {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for device…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            Text("You can also connect later — SnapHaul runs in your menu bar and detects devices automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Spacer()
        }
        .padding(32)
    }

    private func instructionRow(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.body)
        }
    }

    // MARK: - Step 3: ADB Setup

    private var adbSetupStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

            Text("ADB Setup (Optional)")
                .font(.title)
                .fontWeight(.bold)

            Text("ADB (Android Debug Bridge) enables faster batch transfers and more reliable connections for some devices.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if adbDetected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("ADB is already installed")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                .padding()
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                Text("SnapHaul will automatically use ADB when your device has USB Debugging enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("To install ADB via Homebrew:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        Text("brew install android-platform-tools")
                            .font(.system(.body, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                        Button {
                            copyToClipboard("brew install android-platform-tools")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .help("Copy to clipboard")
                    }

                    Text("Then enable USB Debugging on your phone:\nSettings → Developer Options → USB Debugging")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 420)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Text("This step is optional. MTP (File Transfer mode) works without ADB.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button("Re-check") {
                detectADB()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 4: Create Profile

    private var createProfileStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 24)

            Text("Create Your First Profile")
                .font(.title2)
                .fontWeight(.bold)

            Text("A profile tells SnapHaul where to put your files and how to organize them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("My Photos", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("/Users/you/Pictures/SnapHaul", text: $destinationPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            chooseDestination()
                        }
                    }
                }

                Divider()

                Toggle("Auto-start when device connects", isOn: $autoTrigger)
                Toggle("Verify checksums after transfer", isOn: $checksumVerification)
            }
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 440)

            Text("You can create more profiles and customize naming templates in Preferences.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Step indicators
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            // Skip button
            if currentStep != .createProfile {
                Button("Skip") {
                    completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Navigation buttons
            if currentStep.rawValue > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if currentStep == .createProfile {
                Button("Create Profile & Start") {
                    createProfileAndFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(profileName.isEmpty || destinationPath.isEmpty)
            } else {
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    // MARK: - Actions

    private func detectADB() {
        let searchPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        adbDetected = searchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
            || Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "adb") != nil
    }

    private func setDefaultDestination() {
        let pictures = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first?.path ?? (NSHomeDirectory() + "/Pictures")
        destinationPath = pictures + "/SnapHaul"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the destination folder for transferred files."

        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    private func createProfileAndFinish() {
        let profile = IngestProfile(
            name: profileName,
            sourceDirectories: ["/DCIM/Camera"],
            destinationPath: destinationPath,
            autoTrigger: autoTrigger,
            checksumVerification: checksumVerification
        )
        appState.profiles.append(profile)
        appState.saveProfiles()
        completeOnboarding()
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
