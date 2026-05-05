// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import FileProvider
import SnapHaulKit

/// Main entry point for SnapHaul.
///
/// Runs as a menu bar app with an optional main window.
/// Debug flags: `--test-usb`, `--test-mtp`, `--test-adb`
@main
struct SnapHaulApp: App {

    @StateObject private var appState = AppState()
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    init() {
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

    /// Register a placeholder File Provider domain at launch so the device
    /// volume appears in Finder when a device connects.
    private func registerFileProviderDomain() {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("com.snaphaul.device"),
            displayName: "Android Device"
        )

        NSFileProviderManager.add(domain) { error in
            if let error = error as NSError?,
               error.domain == NSFileProviderErrorDomain,
               error.code == NSFileProviderError.providerNotFound.rawValue {
                return
            }
            if let error {
                _ = error
            }
        }
    }

    var body: some Scene {
        Window("SnapHaul", id: "main") {
            MainWindowView(appState: appState)
                .sheet(isPresented: $showWelcome) {
                    WelcomeView(appState: appState, isPresented: $showWelcome)
                }
        }
        .defaultSize(width: 960, height: 640)

        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: "cable.connector")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(appState: appState)
        }
    }
}
