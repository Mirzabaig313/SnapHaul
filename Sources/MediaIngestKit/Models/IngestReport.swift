// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Summary report generated after an ingest session completes.
public struct IngestReport: Sendable, Codable, Identifiable {

    public let id: UUID
    public let profileName: String
    public let deviceName: String
    public let deviceSerial: String
    public let startTime: Date
    public let endTime: Date
    public let totalFiles: Int
    public let successfulFiles: Int
    public let failedFiles: Int
    public let skippedFiles: Int
    public let totalBytesTransferred: UInt64
    public let checksumVerified: Bool
    public let checksumPassed: Int
    public let checksumFailed: Int
    public let errors: [TransferError]

    public init(
        id: UUID = UUID(),
        profileName: String,
        deviceName: String,
        deviceSerial: String,
        startTime: Date,
        endTime: Date,
        totalFiles: Int,
        successfulFiles: Int,
        failedFiles: Int,
        skippedFiles: Int,
        totalBytesTransferred: UInt64,
        checksumVerified: Bool,
        checksumPassed: Int = 0,
        checksumFailed: Int = 0,
        errors: [TransferError] = []
    ) {
        self.id = id
        self.profileName = profileName
        self.deviceName = deviceName
        self.deviceSerial = deviceSerial
        self.startTime = startTime
        self.endTime = endTime
        self.totalFiles = totalFiles
        self.successfulFiles = successfulFiles
        self.failedFiles = failedFiles
        self.skippedFiles = skippedFiles
        self.totalBytesTransferred = totalBytesTransferred
        self.checksumVerified = checksumVerified
        self.checksumPassed = checksumPassed
        self.checksumFailed = checksumFailed
        self.errors = errors
    }

    /// Duration of the ingest session.
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Formatted duration string (e.g., "24m 12s").
    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    /// Average transfer speed in bytes per second.
    public var averageSpeed: UInt64 {
        guard duration > 0 else { return 0 }
        return UInt64(Double(totalBytesTransferred) / duration)
    }
}
