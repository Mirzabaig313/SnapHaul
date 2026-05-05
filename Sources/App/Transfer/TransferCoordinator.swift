// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// Central transfer queue manager.
///
/// Schedules file transfers, tracks per-file and overall progress,
/// handles retries with exponential backoff, and enforces concurrency limits.
///
/// Uses `pullFile(from:to:)` for streaming transfers — files are written
/// directly to disk without loading into memory. Progress is reported
/// via a callback after each file completes.
actor TransferCoordinator {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "transfer"
    )

    /// Maximum concurrent transfer streams.
    /// MTP is single-threaded (libmtp limitation) so only 1 stream.
    /// ADB supports parallel pulls — default 4, reduced to 2 on battery.
    private var maxConcurrentStreams: Int = 4

    /// Maximum errors to accumulate before dropping further error details.
    /// Prevents unbounded memory growth on large transfers with high failure rates.
    private static let maxErrorsRetained = 500

    /// Determine the concurrency limit based on the engine type.
    ///
    /// MTP (libmtp) is single-threaded — concurrent calls just queue on the
    /// actor, wasting task slots. ADB can run parallel `adb pull` processes.
    private func concurrencyLimit(for engine: any TransferEngine) -> Int {
        if engine is MTPEngine {
            return 1
        }
        return maxConcurrentStreams
    }

    /// Maximum retry attempts per file.
    private let maxRetries = 3

    /// Base delay for exponential backoff in nanoseconds (500ms).
    private let baseRetryDelay: UInt64 = 500_000_000

    private var isPaused = false
    private var isCancelled = false

    /// Accumulated state for progress reporting.
    private var completedFiles = 0
    private var transferredBytes: UInt64 = 0
    private var errors: [TransferError] = []

    // MARK: - Transfer

    /// Transfer a batch of files from the device to a local destination.
    ///
    /// Uses `pullFile(from:to:)` for streaming — no file is loaded into memory.
    /// Progress is reported after each file completes.
    ///
    /// - Parameters:
    ///   - files: Files to transfer (from `listFiles`).
    ///   - engine: The transfer engine (MTP or ADB).
    ///   - destinationBase: Local directory to write files into.
    ///   - profileName: Profile name shown in progress updates.
    ///   - progressHandler: Called on each file completion with current progress.
    /// - Returns: Summary of the transfer session.
    func transferFiles(
        _ files: [FileItem],
        using engine: any TransferEngine,
        to destinationBase: URL,
        profileName: String = "",
        progressHandler: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> TransferSummary {
        // Reset state
        isPaused = false
        isCancelled = false
        completedFiles = 0
        transferredBytes = 0
        errors = []

        let totalFiles = files.count
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        let startTime = Date()

        logger.info("Starting transfer: \(totalFiles) files, \(totalBytes) bytes")

        // Ensure destination exists
        try FileManager.default.createDirectory(
            at: destinationBase,
            withIntermediateDirectories: true
        )

        let concurrency = concurrencyLimit(for: engine)
        logger.debug("Concurrency limit: \(concurrency) (engine: \(type(of: engine)))")

        // Process files with bounded concurrency
        try await withThrowingTaskGroup(of: SingleFileResult.self) { group in
            var pending = files.makeIterator()
            var inFlight = 0

            // Seed initial batch up to concurrency limit
            while inFlight < concurrency, let file = pending.next() {
                guard !isCancelled else { break }
                inFlight += 1
                group.addTask {
                    await self.transferSingleFile(
                        file,
                        using: engine,
                        to: destinationBase
                    )
                }
            }

            // As each completes, report progress and start the next
            for try await result in group {
                inFlight -= 1

                switch result {
                case .success(let bytesWritten):
                    completedFiles += 1
                    transferredBytes += bytesWritten
                case .failure(let error):
                    completedFiles += 1
                    // Cap retained errors to prevent unbounded memory growth
                    // on large transfers with high failure rates.
                    if errors.count < Self.maxErrorsRetained {
                        errors.append(error)
                    }
                }

                // Report progress
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesPerSecond = elapsed > 0 ? UInt64(Double(transferredBytes) / elapsed) : 0

                let progress = TransferProgress(
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
                )
                progressHandler(progress)

                // Start next file if available
                if let nextFile = pending.next(), !isCancelled {
                    inFlight += 1
                    group.addTask {
                        await self.transferSingleFile(
                            nextFile,
                            using: engine,
                            to: destinationBase
                        )
                    }
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        logger.info("Transfer complete: \(self.completedFiles)/\(totalFiles) files, \(self.transferredBytes) bytes in \(String(format: "%.1f", duration))s")

        return TransferSummary(
            totalFiles: totalFiles,
            completedFiles: completedFiles,
            failedFiles: errors.count,
            totalBytesTransferred: transferredBytes,
            duration: duration,
            errors: errors
        )
    }

    /// Transfer a single file with retry logic.
    ///
    /// Uses `pullFile(from:to:)` for streaming — the file is written
    /// directly to disk by the engine, never loaded into memory.
    private func transferSingleFile(
        _ file: FileItem,
        using engine: any TransferEngine,
        to destinationBase: URL
    ) async -> SingleFileResult {
        let destinationURL = destinationBase.appendingPathComponent(file.name)

        for attempt in 1...maxRetries {
            // Check pause/cancel
            while isPaused {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if isCancelled {
                return .success(0)
            }

            do {
                let bytesWritten = try await engine.pullFile(
                    from: file.path,
                    to: destinationURL,
                    progress: nil
                )

                // Set F_NOCACHE on the written file to avoid polluting buffer cache
                setNoCacheFlag(at: destinationURL)

                logger.debug("Transferred: \(file.name, privacy: .private(mask: .hash)) (\(bytesWritten) bytes)")
                return .success(bytesWritten)

            } catch {
                logger.warning(
                    "Transfer attempt \(attempt)/\(self.maxRetries) failed for \(file.name, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )

                // Clean up partial file
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

    /// Set F_NOCACHE on a file to hint the OS not to cache future reads.
    ///
    /// KNOWN LIMITATION: This is applied after the file is written and closed.
    /// The write data is already in the buffer cache by this point. Setting
    /// F_NOCACHE on a new O_RDONLY fd only prevents future read caching, not
    /// write caching. True write-through requires F_NOCACHE on the fd *before*
    /// writing, which isn't possible when the engine (libmtp/adb) manages its
    /// own file descriptors. A custom streaming implementation (Phase 3+)
    /// would allow setting F_NOCACHE before the first write.
    private func setNoCacheFlag(at url: URL) {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_NOCACHE, 1)
            close(fd)
        }
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

/// Result of transferring a single file.
private enum SingleFileResult: Sendable {
    case success(UInt64)
    case failure(TransferError)
}

/// Summary of a completed transfer session.
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
        let mbps = Double(averageSpeed) / 1_000_000
        return String(format: "%.1f MB/s", mbps)
    }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}
