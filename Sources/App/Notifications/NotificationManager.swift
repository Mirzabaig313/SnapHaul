// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import UserNotifications
import SnapHaulKit
import os

/// Manages macOS user notifications for device events and transfer status.
///
/// Handles notification permission requests, scheduling, and action handling.
/// All notifications use `UNUserNotificationCenter` for native macOS integration.
@MainActor
final class NotificationManager: NSObject, ObservableObject {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "notifications"
    )

    /// Whether the user has granted notification permission.
    @Published private(set) var isAuthorized = false

    // MARK: - Category & Action IDs

    /// Notification categories for actionable notifications.
    enum Category: String {
        case deviceConnected = "DEVICE_CONNECTED"
        case ingestComplete = "INGEST_COMPLETE"
        case ingestFailed = "INGEST_FAILED"
        case transferError = "TRANSFER_ERROR"
    }

    /// Actions the user can take from a notification.
    enum Action: String {
        case startIngest = "START_INGEST"
        case openInFinder = "OPEN_IN_FINDER"
        case viewDetails = "VIEW_DETAILS"
        case dismiss = "DISMISS"
    }

    // MARK: - Setup

    /// Request notification permission and register categories.
    ///
    /// Call once during app startup. Safe to call multiple times —
    /// subsequent calls just refresh the authorization status.
    func setup() {
        // UNUserNotificationCenter requires a valid app bundle with Info.plist.
        // When running as an SPM executable (swift build), there's no bundle,
        // so we skip notification setup to avoid a crash.
        guard Bundle.main.bundleIdentifier != nil else {
            logger.warning("No bundle identifier — skipping notification setup (SPM executable mode)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register notification categories with actions
        let startAction = UNNotificationAction(
            identifier: Action.startIngest.rawValue,
            title: "Start Ingest",
            options: .foreground
        )
        let openFinderAction = UNNotificationAction(
            identifier: Action.openInFinder.rawValue,
            title: "Open in Finder",
            options: .foreground
        )
        let viewDetailsAction = UNNotificationAction(
            identifier: Action.viewDetails.rawValue,
            title: "View Details",
            options: .foreground
        )

        let deviceCategory = UNNotificationCategory(
            identifier: Category.deviceConnected.rawValue,
            actions: [startAction],
            intentIdentifiers: []
        )
        let completeCategory = UNNotificationCategory(
            identifier: Category.ingestComplete.rawValue,
            actions: [openFinderAction, viewDetailsAction],
            intentIdentifiers: []
        )
        let failedCategory = UNNotificationCategory(
            identifier: Category.ingestFailed.rawValue,
            actions: [viewDetailsAction],
            intentIdentifiers: []
        )
        let errorCategory = UNNotificationCategory(
            identifier: Category.transferError.rawValue,
            actions: [viewDetailsAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([
            deviceCategory, completeCategory, failedCategory, errorCategory
        ])

        // Request authorization
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                if let error {
                    self?.logger.error("Notification auth error: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Notification authorization: \(granted ? "granted" : "denied")")
                }
            }
        }
    }

    // MARK: - Send Notifications

    /// Notify that an Android device was connected.
    func notifyDeviceConnected(deviceName: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Device Connected"
        content.body = "\(deviceName) is ready. Tap to start ingest."
        content.sound = .default
        content.categoryIdentifier = Category.deviceConnected.rawValue

        send(id: "device-connected", content: content)
    }

    /// Notify that a device was disconnected.
    func notifyDeviceDisconnected(deviceName: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Device Disconnected"
        content.body = "\(deviceName) was unplugged."
        content.sound = nil

        send(id: "device-disconnected", content: content)
    }

    /// Notify that an ingest session started.
    func notifyIngestStarted(profileName: String, fileCount: Int) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ingest Started"
        content.body = "\(profileName) — \(fileCount) files detected."
        content.sound = nil

        send(id: "ingest-started", content: content)
    }

    /// Notify that an ingest session completed successfully.
    func notifyIngestComplete(report: IngestReport) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ingest Complete"
        content.body = "\(report.successfulFiles) files (\(ByteFormatter.format(report.totalBytesTransferred))) transferred in \(report.formattedDuration)."
        if report.checksumVerified {
            content.body += " All checksums verified."
        }
        content.sound = .default
        content.categoryIdentifier = Category.ingestComplete.rawValue

        send(id: "ingest-complete", content: content)
    }

    /// Notify that an ingest session failed.
    func notifyIngestFailed(profileName: String, error: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ingest Failed"
        content.body = "\(profileName): \(error)"
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = Category.ingestFailed.rawValue

        send(id: "ingest-failed", content: content)
    }

    /// Notify about transfer errors (files that failed).
    func notifyTransferErrors(failedCount: Int, profileName: String) {
        guard isAuthorized, failedCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transfer Errors"
        content.body = "\(failedCount) file(s) failed to transfer in \(profileName). Tap to view details."
        content.sound = .default
        content.categoryIdentifier = Category.transferError.rawValue

        send(id: "transfer-errors-\(UUID().uuidString.prefix(8))", content: content)
    }

    /// Notify about checksum mismatches.
    func notifyChecksumMismatch(count: Int) {
        guard isAuthorized, count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Checksum Mismatch"
        content.body = "\(count) file(s) failed verification. Re-transfer initiated."
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = Category.transferError.rawValue

        send(id: "checksum-mismatch-\(UUID().uuidString.prefix(8))", content: content)
    }

    /// Notify that a device was disconnected during transfer.
    func notifyDisconnectedDuringTransfer(
        deviceName: String,
        completedFiles: Int,
        totalFiles: Int
    ) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Device Disconnected"
        content.body = "\(deviceName) disconnected. \(completedFiles) of \(totalFiles) files transferred. Reconnect to resume."
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = Category.ingestFailed.rawValue

        send(id: "disconnected-during-transfer", content: content)
    }

    // MARK: - Helpers

    /// Send a notification.
    ///
    /// Static IDs (like "device-connected") are intentional — a new notification
    /// of the same type replaces the previous one, preventing stale banners.
    /// Error notifications use unique IDs so each error is visible separately.
    private func send(id: String, content: UNMutableNotificationContent) {
        // Skip if no bundle (SPM executable mode)
        guard Bundle.main.bundleIdentifier != nil else { return }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Handle notification actions when the user taps a button.
    ///
    /// The completion handler is called immediately — the async Task is
    /// fire-and-forget UI work that the system doesn't need to wait for.
    /// This matches Apple's guidance: "call the handler as soon as you
    /// finish processing the action."
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier

        Task { @MainActor in
            switch actionID {
            case Action.startIngest.rawValue:
                logger.info("User tapped Start Ingest from notification")
                // TODO: Trigger ingest via AppState
            case Action.openInFinder.rawValue:
                logger.info("User tapped Open in Finder from notification")
                // TODO: Open destination folder in Finder
            case Action.viewDetails.rawValue:
                logger.info("User tapped View Details from notification")
                // TODO: Open preferences window to transfer history
            default:
                break
            }
        }

        completionHandler()
    }

    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even when app is frontmost
        completionHandler([.banner, .sound])
    }
}
