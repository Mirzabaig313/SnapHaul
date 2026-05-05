// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Progress state for an active transfer session.
public struct TransferProgress: Sendable, Codable {

    public let profileName: String
    public let totalFiles: Int
    public let completedFiles: Int
    public let totalBytes: UInt64
    public let transferredBytes: UInt64
    public let currentFileName: String?
    public let currentFileProgress: Double
    public let bytesPerSecond: UInt64
    public let startTime: Date
    public let errors: [TransferError]

    public init(
        profileName: String,
        totalFiles: Int,
        completedFiles: Int,
        totalBytes: UInt64,
        transferredBytes: UInt64,
        currentFileName: String? = nil,
        currentFileProgress: Double = 0,
        bytesPerSecond: UInt64 = 0,
        startTime: Date = .now,
        errors: [TransferError] = []
    ) {
        self.profileName = profileName
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.currentFileName = currentFileName
        self.currentFileProgress = currentFileProgress
        self.bytesPerSecond = bytesPerSecond
        self.startTime = startTime
        self.errors = errors
    }

    /// Overall progress as a fraction (0.0 to 1.0).
    public var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    /// Estimated time remaining in seconds.
    public var estimatedSecondsRemaining: TimeInterval? {
        guard bytesPerSecond > 0 else { return nil }
        let remaining = totalBytes - transferredBytes
        return TimeInterval(remaining) / TimeInterval(bytesPerSecond)
    }

    /// Formatted speed string (e.g., "94.2 MB/s").
    public var formattedSpeed: String {
        let mbPerSecond = Double(bytesPerSecond) / 1_000_000
        return String(format: "%.1f MB/s", mbPerSecond)
    }
}

/// A single transfer error for reporting.
public struct TransferError: Sendable, Codable, Identifiable {
    public let id: UUID
    public let filePath: String
    public let message: String
    public let isRetryable: Bool
    public let attemptCount: Int

    public init(
        id: UUID = UUID(),
        filePath: String,
        message: String,
        isRetryable: Bool,
        attemptCount: Int
    ) {
        self.id = id
        self.filePath = filePath
        self.message = message
        self.isRetryable = isRetryable
        self.attemptCount = attemptCount
    }
}
