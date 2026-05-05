// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Cocoa
import FinderSync
import os

/// Finder Sync extension that adds "Send to Android" context menu items.
///
/// Communicates with the SnapHaul host app via XPC to push/pull files
/// and check device connection status.
///
/// NOTE: This file must be compiled as a Finder Sync Extension target in Xcode.
/// Bundle ID: com.snaphaul.app.findersync
/// See generate-xcodeproj.sh for setup instructions.
class FinderSyncExtension: FIFinderSync {

    private let logger = Logger(
        subsystem: "com.snaphaul.findersync",
        category: "extension"
    )

    /// Cached XPC connection to the host app.
    private var _xpcConnection: NSXPCConnection?

    override init() {
        super.init()

        let monitoredDirectories = Self.loadMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = Set(monitoredDirectories)

        // Register badge images
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Synced")!,
            label: "Synced to Android",
            forBadgeIdentifier: "synced"
        )
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Transferring")!,
            label: "Transferring",
            forBadgeIdentifier: "transferring"
        )
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Error")!,
            label: "Transfer Error",
            forBadgeIdentifier: "error"
        )

        logger.info("Finder Sync extension initialized, monitoring \(monitoredDirectories.count) directories")
    }

    // MARK: - XPC Connection

    /// Get or create the XPC connection to the host app.
    ///
    /// The host app registers a Mach service named "com.snaphaul.app.xpc".
    /// Returns nil if the host app is not running.
    private var xpcConnection: NSXPCConnection? {
        if let existing = _xpcConnection, existing.isValid {
            return existing
        }

        let connection = NSXPCConnection(
            machServiceName: "com.snaphaul.app.xpc",
            options: []
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SnapHaulXPCProtocol.self)

        connection.invalidationHandler = { [weak self] in
            self?.logger.info("XPC connection to host app invalidated")
            self?._xpcConnection = nil
        }
        connection.interruptionHandler = { [weak self] in
            self?.logger.warning("XPC connection to host app interrupted — host app may have quit")
            self?._xpcConnection = nil
        }

        connection.resume()
        _xpcConnection = connection
        logger.debug("XPC connection established to host app")
        return connection
    }

    /// Get a proxy to the host app's XPC service.
    private func hostApp() -> SnapHaulXPCProtocol? {
        guard let connection = xpcConnection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("XPC remote object error: \(error.localizedDescription)")
            self?._xpcConnection = nil
        } as? SnapHaulXPCProtocol
    }

    // MARK: - Monitored Directories

    private static func loadMonitoredDirectories() -> [URL] {
        if let groupDefaults = UserDefaults(suiteName: "group.com.snaphaul"),
           let paths = groupDefaults.stringArray(forKey: "monitoredDirectories"),
           !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return [
            URL(fileURLWithPath: NSHomeDirectory() + "/Desktop"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Pictures"),
        ]
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "SnapHaul")

        // Check device connection status to enable/disable items
        var deviceConnected = false
        let semaphore = DispatchSemaphore(value: 0)
        hostApp()?.deviceStatus { data, _ in
            deviceConnected = data != nil
            semaphore.signal()
        }
        // Wait up to 0.5s for the status check — don't block Finder for long
        _ = semaphore.wait(timeout: .now() + 0.5)

        let sendItem = NSMenuItem(
            title: "Send to Android",
            action: #selector(sendToAndroid(_:)),
            keyEquivalent: ""
        )
        sendItem.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "Send to Android")
        sendItem.isEnabled = deviceConnected
        menu.addItem(sendItem)

        let chooseItem = NSMenuItem(
            title: "Send to Android → Choose Destination…",
            action: #selector(sendToAndroidChooseDestination(_:)),
            keyEquivalent: ""
        )
        chooseItem.isEnabled = deviceConnected
        menu.addItem(chooseItem)

        menu.addItem(NSMenuItem.separator())

        let verifyItem = NSMenuItem(
            title: "Verify Checksum Against Android",
            action: #selector(verifyChecksum(_:)),
            keyEquivalent: ""
        )
        verifyItem.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Verify Checksum")
        verifyItem.isEnabled = deviceConnected
        menu.addItem(verifyItem)

        if !deviceConnected {
            menu.addItem(NSMenuItem.separator())
            let statusItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        return menu
    }

    // MARK: - Actions

    @objc private func sendToAndroid(_ sender: Any?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return }

        logger.info("Send to Android: \(items.count) file(s)")

        // Default destination: /sdcard/SnapHaul/
        let defaultRemoteDir = "/sdcard/SnapHaul"

        for url in items {
            let remotePath = "\(defaultRemoteDir)/\(url.lastPathComponent)"
            hostApp()?.pushFile(from: url.path, to: remotePath) { [weak self] success, error in
                if let error {
                    self?.logger.error("Failed to push \(url.lastPathComponent): \(error.localizedDescription)")
                } else {
                    self?.logger.info("Pushed \(url.lastPathComponent) → \(remotePath)")
                    // Update badge to show synced
                    DispatchQueue.main.async {
                        FIFinderSyncController.default().setBadgeIdentifier("synced", for: url)
                    }
                }
            }
        }
    }

    @objc private func sendToAndroidChooseDestination(_ sender: Any?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return }

        logger.info("Send to Android (choose destination): \(items.count) file(s)")

        // Fetch the device's root directory listing via XPC so the user can pick a folder
        hostApp()?.listFiles(at: "/sdcard") { [weak self] data, error in
            guard let self else { return }

            if let error {
                self.logger.error("Failed to list device root: \(error.localizedDescription)")
                // Fall back to default destination
                DispatchQueue.main.async {
                    self.sendFilesToPath(items, remotePath: "/sdcard/SnapHaul")
                }
                return
            }

            // For now, use a simple text input dialog to get the destination path.
            // A full folder picker would require a separate UI process.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Choose Android Destination"
                alert.informativeText = "Enter the device folder path to send \(items.count) file(s) to:"
                alert.addButton(withTitle: "Send")
                alert.addButton(withTitle: "Cancel")

                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                input.stringValue = "/sdcard/SnapHaul"
                alert.accessoryView = input

                if alert.runModal() == .alertFirstButtonReturn {
                    let path = input.stringValue.trimmingCharacters(in: .whitespaces)
                    if !path.isEmpty {
                        self.sendFilesToPath(items, remotePath: path)
                    }
                }
            }
        }
    }

    private func sendFilesToPath(_ items: [URL], remotePath: String) {
        for url in items {
            let dest = "\(remotePath)/\(url.lastPathComponent)"
            hostApp()?.pushFile(from: url.path, to: dest) { [weak self] success, error in
                if let error {
                    self?.logger.error("Push failed for \(url.lastPathComponent): \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        FIFinderSyncController.default().setBadgeIdentifier("error", for: url)
                    }
                } else {
                    self?.logger.info("Pushed \(url.lastPathComponent) → \(dest)")
                    DispatchQueue.main.async {
                        FIFinderSyncController.default().setBadgeIdentifier("synced", for: url)
                    }
                }
            }
        }
    }

    @objc private func verifyChecksum(_ sender: Any?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return }

        logger.info("Verify checksum: \(items.count) file(s)")

        for url in items {
            // Step 1: Compute local checksum via XPC (host app does the hashing)
            hostApp()?.checksumLocalFile(at: url.path) { [weak self] localHash, error in
                guard let self, let localHash else {
                    self?.logger.error("Local checksum failed for \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown")")
                    return
                }

                // Step 2: The remote path is assumed to be /sdcard/SnapHaul/<filename>
                // In a full implementation, we'd look this up from the manifest DB.
                let remotePath = "/sdcard/SnapHaul/\(url.lastPathComponent)"

                // Step 3: Pull the remote file to a temp location and hash it
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("snaphaul-verify-\(url.lastPathComponent)")

                self.hostApp()?.pullFile(from: remotePath, to: tempURL.path) { [weak self] _, pullError in
                    defer { try? FileManager.default.removeItem(at: tempURL) }

                    if let pullError {
                        self?.logger.error("Could not pull remote file for verification: \(pullError.localizedDescription)")
                        return
                    }

                    self?.hostApp()?.checksumLocalFile(at: tempURL.path) { [weak self] remoteHash, _ in
                        guard let remoteHash else { return }

                        let match = localHash == remoteHash
                        self?.logger.info("Checksum \(match ? "✓ MATCH" : "✗ MISMATCH") for \(url.lastPathComponent)")

                        DispatchQueue.main.async {
                            FIFinderSyncController.default().setBadgeIdentifier(
                                match ? "synced" : "error",
                                for: url
                            )

                            // Show result alert
                            let alert = NSAlert()
                            alert.messageText = match ? "Checksum Verified ✓" : "Checksum Mismatch ✗"
                            alert.informativeText = match
                                ? "\(url.lastPathComponent) matches the copy on your Android device."
                                : "\(url.lastPathComponent) does NOT match the device copy. The file may have been modified."
                            alert.alertStyle = match ? .informational : .warning
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Badge Support

    override func requestBadgeIdentifier(for url: URL) {
        // Check if this file has been synced to the device by querying the host app
        // For now, we don't set a badge unless an action was taken
        // A full implementation would query the manifest DB via XPC
    }
}
