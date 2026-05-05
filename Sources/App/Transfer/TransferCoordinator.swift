// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// Central transfer queue manager.
///
/// Schedules file transfers, tracks progress, handles retries with exponential
/// backoff, and enforces concurrency limits. Adapts behavior based on power
/// state and calibrated USB throughput.
actor TransferCoordinator {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "transfer"
    )

    private var maxConcurrentStreams: Int = 4
    private static let maxErrorsRetained = 500
    private var progressUpdateInterval: Int = 1

    private var throughputSamples: [Double] = []
    private(set) var calibratedThroughput: Double = 0
    private var isCalibrated: Bool { throughputSamples.count >= 3 }

    private var currentQoS: DispatchQoS.QoSClass = .utility

    /// Pre-allocated buffer pool for transfer I/O (4 × 4 MB page-aligned buffers).
    /// Eliminates per-file allocation churn during large ingest sessions.
    private let bufferPool = TransferBufferPool(bufferSize: 4 * 1024 * 1024, count: 4)

    /// Update concurrency and QoS based on power state.
    func updatePowerSettings(isOnBattery: Bool, isAppForeground: Bool) {
        maxConcurrentStreams = isOnBattery ? 2 : 4
        progressUpdateInterval = isOnBattery ? 5 : 1
        currentQoS = resolveQoS(isOnBattery: isOnBattery, isAppForeground: isAppForeground)
        logger.info("Power settings: concurrency=\(self.maxConcurrentStreams), QoS=\(String(describing: self.currentQoS))")
    }

    private func resolveQoS(isOnBattery: Bool, isAppForeground: Bool) -> DispatchQoS.QoSClass {
        if !isAppForeground { return .background }
        return isOnBattery ? .utility : .userInitiated
    }

    private func concurrencyLimit(for engine: any TransferEngine) -> Int {
        engine is MTPEngine ? 1 : maxConcurrentStreams
    }

    private let maxRetries = 3
    private let baseRetryDelay: UInt64 = 500_000_000

    private var isPaused = false
    private var isCancelled = false
    private var completedFiles = 0
    private var transferredBytes: UInt64 = 0
    private var errors: [TransferError] = []

    // MARK: - Transfer

    /// Transfer a batch of files from the device to a local destination.
    func transferFiles(
        _ files: [FileItem],
        using engine: any TransferEngine,
        to destinationBase: URL,
        profileName: String = "",
        progressHandler: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> TransferSummary {
        isPaused = false
        isCancelled = false
        completedFiles = 0
        transferredBytes = 0
        errors = []
        transferredURLs = []

        let totalFiles = files.count
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        let startTime = Date()

        logger.info("Starting transfer: \(totalFiles) files, \(totalBytes) bytes")

        try FileManager.default.createDirectory(
            at: destinationBase,
            withIntermediateDirectories: true
        )

        let concurrency = concurrencyLimit(for: engine)

        try await withThrowingTaskGroup(of: SingleFileResult.self) { group in
            var pending = files.makeIterator()
            var inFlight = 0

            while inFlight < concurrency, let file = pending.next() {
                guard !isCancelled else { break }
                inFlight += 1
                group.addTask {
                    await self.transferSingleFile(file, using: engine, to: destinationBase)
                }
            }

            for try await result in group {
                inFlight -= 1

                switch result {
                case .success(let bytesWritten):
                    completedFiles += 1
                    transferredBytes += bytesWritten
                case .failure(let error):
                    completedFiles += 1
                    if errors.count < Self.maxErrorsRetained {
                        errors.append(error)
                    }
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let bytesPerSecond = elapsed > 0 ? UInt64(Double(transferredBytes) / elapsed) : 0

                let shouldReport = completedFiles % progressUpdateInterval == 0
                    || completedFiles == totalFiles

                if shouldReport {
                    progressHandler(TransferProgress(
                        profileName: profileName,
                        totalFiles: totalFiles,
                        completedFiles: completedFiles,
                        totalBytes: totalBytes,
                        transferredBytes: transferredBytes,
                        currentFileName: nil,
                        currentFileProgress: 1.0,
                        bytesPerSecond: bytesPerSecond,
                        startTime: startTime,
                        errors: errors
                    ))
                }

                if let nextFile = pending.next(), !isCancelled {
                    inFlight += 1
                    group.addTask {
                        await self.transferSingleFile(nextFile, using: engine, to: destinationBase)
                    }
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        logger.info("Transfer complete: \(self.completedFiles)/\(totalFiles) in \(String(format: "%.1f", duration))s")

        // Batch Spotlight operations: suppress all at once, then re-enable after session
        batchSuppressSpotlight()
        enableSpotlightIndexing()

        return TransferSummary(
            totalFiles: totalFiles,
            completedFiles: completedFiles,
            failedFiles: errors.count,
            totalBytesTransferred: transferredBytes,
            duration: duration,
            errors: errors
        )
    }

    /// Transfer a single file with retry and throughput calibration.
    private func transferSingleFile(
        _ file: FileItem,
        using engine: any TransferEngine,
        to destinationBase: URL
    ) async -> SingleFileResult {
        let destinationURL = destinationBase.appendingPathComponent(file.name)

        for attempt in 1...maxRetries {
            while isPaused {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if isCancelled { return .success(0) }

            do {
                let fileStart = Date()

                let bytesWritten = try await engine.pullFile(
                    from: file.path,
                    to: destinationURL,
                    progress: nil
                )

                setNoCacheFlag(at: destinationURL)
                suppressSpotlightIndexing(at: destinationURL)

                if !isCalibrated && bytesWritten > 0 {
                    let elapsed = Date().timeIntervalSince(fileStart)
                    if elapsed > 0.01 && throughputSamples.count < 3 {
                        throughputSamples.append(Double(bytesWritten) / elapsed)
                        if throughputSamples.count == 3 {
                            calibratedThroughput = throughputSamples.reduce(0, +) / 3.0
                            logger.info("Throughput calibrated: \(String(format: "%.1f", self.calibratedThroughput / 1_000_000)) MB/s")
                        }
                    }
                }

                return .success(bytesWritten)

            } catch {
                logger.warning("Attempt \(attempt)/\(self.maxRetries) failed: \(file.name, privacy: .private(mask: .hash))")
                try? FileManager.default.removeItem(at: destinationURL)

                if attempt < maxRetries {
                    let delay = baseRetryDelay * UInt64(1 << (attempt - 1))
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    return .failure(TransferError(
                        filePath: file.path,
                        message: error.localizedDescription,
                        isRetryable: true,
                        attemptCount: maxRetries
                    ))
                }
            }
        }

        return .failure(TransferError(
            filePath: file.path,
            message: "Max retries exceeded",
            isRetryable: false,
            attemptCount: maxRetries
        ))
    }

    /// Prevent buffer cache pollution on transferred files.
    private func setNoCacheFlag(at url: URL) {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_NOCACHE, 1)
            close(fd)
        }
    }

    /// Suppress Spotlight indexing during transfer.
    private func suppressSpotlightIndexing(at url: URL) {
        transferredURLs.append(url)
    }

    private var transferredURLs: [URL] = []

    /// Batch-suppress Spotlight for all accumulated URLs, then re-enable after transfer.
    /// Uses batch C call to minimize per-file syscall overhead.
    private func batchSuppressSpotlight() {
        guard !transferredURLs.isEmpty else { return }
        SpotlightControl.suppressBatch(urls: transferredURLs)
    }

    /// Re-enable Spotlight indexing for all transferred files in batch.
    func enableSpotlightIndexing() {
        SpotlightControl.enableBatch(urls: transferredURLs)
        let count = transferredURLs.count
        transferredURLs.removeAll()
        if count > 0 {
            logger.info("Re-enabled Spotlight indexing for \(count) files")
        }
    }

    // MARK: - Adaptive Chunk Sizing

    /// Recommended chunk size based on file size and calibrated throughput.
    func recommendedChunkSize(for fileSize: UInt64) -> Int {
        if isCalibrated && calibratedThroughput < 25_000_000 {
            return 1_048_576
        }

        switch fileSize {
        case 0..<1_048_576:
            return max(Int(fileSize), 65_536)
        case 1_048_576..<104_857_600:
            return 4_194_304
        case 104_857_600..<1_073_741_824:
            return 8_388_608
        default:
            return 16_777_216
        }
    }

    var isUSB2Speed: Bool {
        isCalibrated && calibratedThroughput < 25_000_000
    }

    // MARK: - Control

    nonisolated func pauseAll() {
        Task { await setPaused(true) }
    }

    nonisolated func resumeAll() {
        Task { await setPaused(false) }
    }

    nonisolated func cancelAll() {
        Task { await setCancelled(true) }
    }

    private func setPaused(_ value: Bool) {
        isPaused = value
        logger.info("Transfer \(value ? "paused" : "resumed")")
    }

    private func setCancelled(_ value: Bool) {
        isCancelled = value
        if value { logger.info("Transfer cancelled") }
    }
}

// MARK: - Result Types

private enum SingleFileResult: Sendable {
    case success(UInt64)
    case failure(TransferError)
}

struct TransferSummary: Sendable {
    let totalFiles: Int
    let completedFiles: Int
    let failedFiles: Int
    let totalBytesTransferred: UInt64
    let duration: TimeInterval
    let errors: [TransferError]

    var averageSpeed: UInt64 {
        guard duration > 0 else { return 0 }
        return UInt64(Double(totalBytesTransferred) / duration)
    }

    var formattedSpeed: String {
        String(format: "%.1f MB/s", Double(averageSpeed) / 1_000_000)
    }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}
