// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import FileProvider
import SnapHaulKit

/// Main entry point for SnapHaul.
///
/// Runs as a menu bar app (NSStatusItem) with an optional settings window.
/// The app lifecycle:
/// 1. Launch → appear in menu bar
/// 2. Start DeviceMonitor (IOKit USB notifications)
/// 3. On device connect → show notification, optionally auto-trigger ingest
/// 4. User interacts via menu bar popover or Preferences window
///
/// Debug flags:
/// - `--test-usb`: Run the USB monitor test (prints device info to console)
/// - `--test-mtp`: Run the MTP connectivity and transfer test
/// - `--test-adb`: Run the ADB connectivity and transfer test
@main
struct SnapHaulApp: App {

    @StateObject private var appState = AppState()
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    init() {
        // Register the File Provider domain so the device volume can appear
        // in Finder. This is a no-op if the domain is already registered.
        // The actual device name is updated when a device connects.
        registerFileProviderDomain()

        #if DEBUG
        if CommandLine.arguments.contains("--test-usb") {
            USBMonitorTest.run()
        }
        if CommandLine.arguments.contains("--test-mtp") {
            MTPTest.run()
        }
        if CommandLine.arguments.contains("--test-adb") {
            ADBTest.run()
        }
        #endif
    }

    /// Register the SnapHaul File Provider domain with macOS.
    ///
    /// The domain represents the connected Android device in Finder.
    /// We register a placeholder domain at launch; the display name
    /// is updated to the actual device name when a device connects.
    ///
    /// This must be called before the device connects so macOS has time
    /// to set up the volume. The domain persists across app launches.
    private func registerFileProviderDomain() {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("com.snaphaul.device"),
            displayName: "Android Device"
        )

        NSFileProviderManager.add(domain) { error in
            if let error = error as NSError?,
               error.domain == NSFileProviderErrorDomain,
               error.code == NSFileProviderError.providerNotFound.rawValue {
                // Extension not yet installed — expected during development
                // before the Xcode project is fully set up.
                return
            }
            if let error {
                // Domain may already be registered — that's fine.
                // NSFileProviderManager.add is idempotent for the same identifier.
                _ = error  // suppress unused warning
            }
        }
    }

    var body: some Scene {
        // Main app window — full file manager
        Window("SnapHaul", id: "main") {
            MainWindowView(appState: appState)
                .sheet(isPresented: $showWelcome) {
                    WelcomeView(appState: appState, isPresented: $showWelcome)
                }
        }
        .defaultSize(width: 960, height: 640)

        // Menu bar extra — quick access
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: "cable.connector")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened from menu bar or ⌘,
        Settings {
            PreferencesView(appState: appState)
        }
    }
}
