// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SwiftUI
import FileProvider
import Combine
import GRDB
import SnapHaulKit
import os

/// Central application state, observable by all SwiftUI views.
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
    let powerManager = PowerManager()
    let database: AppDatabase?

    private(set) var activeEngine: (any TransferEngine)?
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

        var db: AppDatabase?
        do {
            db = try AppDatabase()
        } catch {
            let logger = Logger(subsystem: "com.snaphaul.app", category: "appstate")
            logger.error("Failed to initialize database: \(error.localizedDescription)")
            db = nil
        }
        self.database = db

        if let dbQueue = db?.dbQueue {
            self.ingestEngine = IngestEngine(database: dbQueue)
        } else {
            let fallbackQueue: DatabaseQueue
            do {
                fallbackQueue = try DatabaseQueue()
            } catch {
                fatalError("Cannot create in-memory database: \(error)")
            }
            self.ingestEngine = IngestEngine(database: fallbackQueue)
            let logger = Logger(subsystem: "com.snaphaul.app", category: "appstate")
            logger.warning("Using in-memory database fallback — delta-sync will not persist")
        }

        self.profiles = profileStore.loadAll()

        logger.info("SnapHaul initialized")
        notificationManager.setup()
        xpcService.appState = self
        xpcService.start()
        startMonitoring()
        startPowerObservation()
    }

    // MARK: - Profile Management

    func reloadProfiles() {
        profiles = profileStore.loadAll()
    }

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

    /// Observe power state changes and propagate to the transfer coordinator.
    private func startPowerObservation() {
        Task {
            await transferCoordinator.updatePowerSettings(
                isOnBattery: powerManager.isOnBattery,
                isAppForeground: powerManager.isAppForeground
            )
        }

        powerManager.$isOnBattery.sink { [weak self] isOnBattery in
            guard let self else { return }
            Task {
                await self.transferCoordinator.updatePowerSettings(
                    isOnBattery: isOnBattery,
                    isAppForeground: self.powerManager.isAppForeground
                )
            }
        }.store(in: &cancellables)

        powerManager.$isAppForeground.sink { [weak self] isForeground in
            guard let self else { return }
            Task {
                await self.transferCoordinator.updatePowerSettings(
                    isOnBattery: self.powerManager.isOnBattery,
                    isAppForeground: isForeground
                )
            }
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.powerManager.isAppForeground = true
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.powerManager.isAppForeground = false
        }
    }

    /// Combine cancellables.
    private var cancellables: Set<AnyCancellable> = []

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

        updateFileProviderDomainName(device.displayName)

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
                let engine = self.engineSelector.selectEngine(
                    for: usbDevice,
                    userPreference: UserDefaults.standard.string(forKey: "preferredEngine") ?? "auto",
                    adbAvailable: self.isADBAvailable
                )

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
                    self.activeEngine = nil

                    self.notificationManager.notifyIngestFailed(
                        profileName: profile.name,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Start an ingest session using a profile name.
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

    private func updateFileProviderDomainName(_ deviceName: String) {
        let domainID = NSFileProviderDomainIdentifier("com.snaphaul.device")
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let domain = domains.first(where: { $0.identifier == domainID }) else { return }
            NSFileProviderManager(for: domain)?.signalEnumerator(
                for: .rootContainer,
                completionHandler: { _ in }
            )
        }
    }

    private var isADBAvailable: Bool {
        let searchPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if searchPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        return Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "adb") != nil
    }

    // MARK: - Device File Browser

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

    /// Pull a file with live progress polling (fires every ~0.3s).
    func pullFile(
        from remotePath: String,
        to localURL: URL,
        onBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }

        let pollTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { break }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                   let size = attrs[.size] as? UInt64, size > 0 {
                    onBytesWritten(size)
                }
            }
        }

        let totalBytes = try await engine.pullFile(from: remotePath, to: localURL, progress: nil)

        pollTask.cancel()
        onBytesWritten(totalBytes)

        return totalBytes
    }

    func pushFile(data: Data, to remotePath: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        try await engine.writeFile(at: remotePath, data: data)
    }

    /// Push a local file to the device. Uses memory-mapped reads.
    func pushFile(from localURL: URL, to remotePath: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        try await engine.writeFile(at: remotePath, data: data)
    }

    func renameFile(at remotePath: String, to newName: String) async throws {
        guard let engine = activeEngine else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        try await engine.renameFile(at: remotePath, to: newName)
    }
}
