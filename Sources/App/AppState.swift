// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SwiftUI
import FileProvider
import GRDB
import SnapHaulKit
import os

/// Central application state, observable by all SwiftUI views.
///
/// Owns the device monitor, transfer coordinator, and ingest engine.
/// Acts as the single source of truth for the app's runtime state.
/// Wires live progress from the transfer coordinator to the UI.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published private(set) var deviceState: DeviceState?
    @Published private(set) var transferProgress: TransferProgress?
    @Published private(set) var isTransferring: Bool = false
    @Published private(set) var lastReport: IngestReport?
    @Published private(set) var connectedUSBDevice: USBDevice?
    @Published var profiles: [IngestProfile] = []
    @Published var showingDeviceBrowser = false

    // MARK: - Subsystems

    private let deviceMonitor: DeviceMonitor
    private let engineSelector: EngineSelector
    private let transferCoordinator: TransferCoordinator
    private let ingestEngine: IngestEngine
    private let profileStore: ProfileStore
    private let notificationManager: NotificationManager
    private let xpcService: XPCService
    let database: AppDatabase?

    /// The currently active transfer engine (MTP or ADB).
    /// Exposed for XPC handler access.
    private(set) var activeEngine: (any TransferEngine)?

    /// Handle to the running transfer task so we can cancel it.
    private var transferTask: Task<Void, Never>?

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "appstate"
    )

    // MARK: - Init

    init() {
        self.deviceMonitor = DeviceMonitor()
        self.engineSelector = EngineSelector()
        self.transferCoordinator = TransferCoordinator()
        self.profileStore = ProfileStore()
        self.notificationManager = NotificationManager()
        self.xpcService = XPCService()

        // Initialize database with error handling
        var db: AppDatabase?
        do {
            db = try AppDatabase()
        } catch {
            let logger = Logger(subsystem: "com.snaphaul.app", category: "appstate")
            logger.error("Failed to initialize database: \(error.localizedDescription)")
            db = nil
        }
        self.database = db

        // Initialize IngestEngine with database (or a fallback in-memory queue)
        if let dbQueue = db?.dbQueue {
            self.ingestEngine = IngestEngine(database: dbQueue)
        } else {
            // Fallback: in-memory database — delta-sync won't persist across launches
            let fallbackQueue: DatabaseQueue
            do {
                fallbackQueue = try DatabaseQueue()
            } catch {
                // This should never happen — in-memory DB creation is infallible
                // in practice. If it does, something is catastrophically wrong.
                fatalError("Cannot create in-memory database: \(error)")
            }
            self.ingestEngine = IngestEngine(database: fallbackQueue)
            let logger = Logger(subsystem: "com.snaphaul.app", category: "appstate")
            logger.warning("Using in-memory database fallback — delta-sync will not persist")
        }

        // Load saved profiles — no auto-default, user creates profiles in Preferences
        self.profiles = profileStore.loadAll()

        logger.info("SnapHaul initialized")
        notificationManager.setup()
        xpcService.appState = self
        xpcService.start()
        startMonitoring()
    }

    // MARK: - Profile Management

    /// Reload profiles from persistent storage.
    func reloadProfiles() {
        profiles = profileStore.loadAll()
    }

    /// Save the current profiles array to persistent storage.
    func saveProfiles() {
        profileStore.saveAll(profiles)
    }

    // MARK: - Device Monitoring

    private func startMonitoring() {
        deviceMonitor.onDeviceConnected = { [weak self] device in
            Task { @MainActor in
                self?.handleDeviceConnected(device)
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] serial in
            Task { @MainActor in
                self?.handleDeviceDisconnected(serial: serial)
            }
        }

        deviceMonitor.startMonitoring()
    }

    private func handleDeviceConnected(_ device: DeviceState) {
        logger.info("Device connected: \(device.displayName) [\(device.redactedSerial)]")
        deviceState = device

        connectedUSBDevice = USBDevice(
            serialNumber: device.serialNumber,
            vendorID: 0,
            productID: 0,
            displayName: device.displayName,
            manufacturer: device.manufacturer,
            usbMode: device.engineType == .adb ? .adb : .mtp,
            usbSpeed: .unknown
        )

        notificationManager.notifyDeviceConnected(deviceName: device.displayName)

        // Update the File Provider domain display name to the actual device name
        // so Finder shows "Samsung Galaxy S25" instead of "Android Device".
        updateFileProviderDomainName(device.displayName)

        // Auto-trigger any profiles configured to start on device connect.
        // Only start the first matching profile — running multiple simultaneous
        // ingests on connect would be surprising and resource-intensive.
        if let autoProfile = profiles.first(where: { $0.autoTrigger }) {
            logger.info("Auto-triggering ingest profile: \(autoProfile.name)")
            startIngest(profile: autoProfile)
        }
    }

    private func handleDeviceDisconnected(serial: String) {
        let redacted = String(serial.suffix(4))
        logger.info("Device disconnected: [***\(redacted)]")

        let disconnectedDeviceName = deviceState?.displayName ?? "Device"

        if let engine = activeEngine {
            Task { await engine.disconnect() }
            activeEngine = nil
        }

        deviceState = nil
        connectedUSBDevice = nil

        if isTransferring {
            let progress = transferProgress
            transferTask?.cancel()
            transferCoordinator.cancelAll()
            isTransferring = false
            transferProgress = nil

            notificationManager.notifyDisconnectedDuringTransfer(
                deviceName: disconnectedDeviceName,
                completedFiles: progress?.completedFiles ?? 0,
                totalFiles: progress?.totalFiles ?? 0
            )
        } else {
            notificationManager.notifyDeviceDisconnected(deviceName: disconnectedDeviceName)
        }
    }

    // MARK: - Transfer Actions

    /// Start an ingest session using the given profile.
    ///
    /// Selects the appropriate engine (MTP or ADB), connects to the device,
    /// and runs the full ingest pipeline via IngestEngine.
    func startIngest(profile: IngestProfile) {
        guard let device = deviceState else {
            logger.warning("Cannot start ingest: no device connected")
            return
        }
        guard let usbDevice = connectedUSBDevice else {
            logger.warning("Cannot start ingest: no USB device info available")
            return
        }
        guard !isTransferring else {
            logger.warning("Cannot start ingest: transfer already in progress")
            return
        }

        logger.info("Starting ingest with profile: \(profile.name) for \(device.displayName)")
        isTransferring = true
        transferProgress = nil
        notificationManager.notifyIngestStarted(profileName: profile.name, fileCount: 0)

        transferTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Select engine based on device state and user preference
                let engine = self.engineSelector.selectEngine(
                    for: usbDevice,
                    userPreference: UserDefaults.standard.string(forKey: "preferredEngine") ?? "auto",
                    adbAvailable: self.isADBAvailable
                )

                // Set activeEngine before connecting so the device browser
                // can use it even if ingest fails partway through.
                await MainActor.run { self.activeEngine = engine }

                try await engine.connect(device: usbDevice)

                let report = try await self.ingestEngine.runIngest(
                    profile: profile,
                    deviceSerial: device.serialNumber,
                    engine: engine,
                    coordinator: self.transferCoordinator
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.transferProgress = progress
                    }
                }

                await MainActor.run {
                    self.lastReport = report
                    self.logger.info("Ingest complete: \(report.successfulFiles)/\(report.totalFiles) files")
                    self.isTransferring = false
                    self.transferProgress = nil

                    self.notificationManager.notifyIngestComplete(report: report)
                    if report.failedFiles > 0 {
                        self.notificationManager.notifyTransferErrors(
                            failedCount: report.failedFiles,
                            profileName: profile.name
                        )
                    }
                    if report.checksumFailed > 0 {
                        self.notificationManager.notifyChecksumMismatch(count: report.checksumFailed)
                    }
                }

            } catch {
                await MainActor.run {
                    self.logger.error("Ingest failed: \(error.localizedDescription)")
                    self.isTransferring = false
                    self.transferProgress = nil
                    // Clear the engine — it may be in a bad state after the error.
                    // The device browser will reconnect on next use.
                    self.activeEngine = nil

                    self.notificationManager.notifyIngestFailed(
                        profileName: profile.name,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Start an ingest session using a profile name (convenience).
    func startIngest(profileName: String) {
        guard let profile = profiles.first(where: { $0.name == profileName }) else {
            logger.warning("Profile not found: \(profileName)")
            return
        }
        startIngest(profile: profile)
    }

    func pauseTransfer() {
        transferCoordinator.pauseAll()
        logger.info("Transfer paused")
    }

    func resumeTransfer() {
        transferCoordinator.resumeAll()
        logger.info("Transfer resumed")
    }

    func stopTransfer() {
        transferTask?.cancel()
        transferCoordinator.cancelAll()
        isTransferring = false
        transferProgress = nil
        logger.info("Transfer stopped")
    }

    // MARK: - Helpers

    /// Update the File Provider domain display name to match the connected device.
    private func updateFileProviderDomainName(_ deviceName: String) {
        let domainID = NSFileProviderDomainIdentifier("com.snaphaul.device")
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let domain = domains.first(where: { $0.identifier == domainID }) else {
                return
            }
            // Signal the File Provider to re-enumerate so Finder refreshes
            NSFileProviderManager(for: domain)?.signalEnumerator(
                for: .rootContainer,
                completionHandler: { _ in }
            )
        }
    }

    /// Whether an ADB binary is available on this machine.
    ///
    /// Checks the same search paths as ADBEngine so the engine selector
    /// and the engine itself agree on availability.
    private var isADBAvailable: Bool {
        let searchPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if searchPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        // Also check if a bundled adb exists in the app bundle
        return Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "adb") != nil
    }

    // MARK: - Device File Browser

    /// Connect to the device engine (if not already connected) and list files at the given path.
    func listDeviceFiles(at path: String) async throws -> [FileItem] {
        guard let usbDevice = connectedUSBDevice else {
            throw ADBError.deviceOffline(device: "unknown")
        }

        if activeEngine == nil {
            let engine = engineSelector.selectEngine(
                for: usbDevice,
                userPreference: UserDefaults.standard.string(forKey: "preferredEngine") ?? "auto",
                adbAvailable: isADBAvailable
            )
            try await engine.connect(device: usbDevice)
            activeEngine = engine
        }

        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: usbDevice.displayName)
        }

        return try await engine.listFiles(at: path)
    }

    /// Pull a single file from the device to a local URL.
    func pullFile(from remotePath: String, to localURL: URL) async throws -> UInt64 {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        return try await engine.pullFile(from: remotePath, to: localURL, progress: nil)
    }

    /// Pull a single file with a live byte-count progress callback.
    ///
    /// The callback fires periodically with the total bytes written so far.
    /// For ADB, it fires once at the end (adb pull doesn't report mid-transfer).
    /// For MTP, it fires once at the end (libmtp progress callback is Phase 3).
    ///
    /// To get smooth progress for large files, we poll the destination file
    /// size on a timer while the engine transfer runs.
    func pullFile(
        from remotePath: String,
        to localURL: URL,
        onBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }

        // Start a polling task that checks the file size every 0.3s.
        // This gives smooth progress even though the engine only reports
        // bytes at the end — the file grows on disk as the engine writes.
        let pollTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                guard !Task.isCancelled else { break }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                   let size = attrs[.size] as? UInt64, size > 0 {
                    onBytesWritten(size)
                }
            }
        }

        let totalBytes = try await engine.pullFile(from: remotePath, to: localURL, progress: nil)

        // Stop polling and report final size
        pollTask.cancel()
        onBytesWritten(totalBytes)

        return totalBytes
    }

    /// Push data to a file on the device.
    func pushFile(data: Data, to remotePath: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        try await engine.writeFile(at: remotePath, data: data)
    }

    /// Push a local Mac file to the device by path.
    ///
    /// Reads the file lazily — does not load the entire file into memory.
    /// Used by the XPC handler so the Finder Sync extension can push files
    /// without the host app buffering them.
    func pushFile(from localURL: URL, to remotePath: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        // Read with .mappedIfSafe so the OS pages in only what the engine reads.
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        try await engine.writeFile(at: remotePath, data: data)
    }

    /// Rename a file on the device (same directory, new filename only).
    func renameFile(at remotePath: String, to newName: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        try await engine.renameFile(at: remotePath, to: newName)
    }
}
