// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Errors originating from the ingest engine.
public enum IngestError: Error, LocalizedError, Sendable {

    case profileNotFound(name: String)
    case destinationNotAccessible(path: String)
    case destinationDiskFull(path: String, availableBytes: UInt64, requiredBytes: UInt64)
    case sourceDirectoryNotFound(path: String)
    case noFilesMatchFilter(profile: String)
    case manifestCorrupted(profile: String)
    case namingTemplateInvalid(template: String, reason: String)
    case deviceDisconnectedDuringIngest
    case checksumVerificationFailed(fileCount: Int)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let name):
            return "Ingest profile not found: \(name)"
        case .destinationNotAccessible(let path):
            return "Destination is not accessible: \(path). Ensure the volume is mounted."
        case .destinationDiskFull(let path, let available, let required):
            let availableMB = available / 1_000_000
            let requiredMB = required / 1_000_000
            return "Destination disk nearly full at \(path). Available: \(availableMB) MB, needed: \(requiredMB) MB."
        case .sourceDirectoryNotFound(let path):
            return "Source directory not found on device: \(path)"
        case .noFilesMatchFilter(let profile):
            return "No files match the filters in profile: \(profile)"
        case .manifestCorrupted(let profile):
            return "Sync manifest corrupted for profile: \(profile). Rebuilding."
        case .namingTemplateInvalid(let template, let reason):
            return "Invalid naming template '\(template)': \(reason)"
        case .deviceDisconnectedDuringIngest:
            return "Device disconnected during ingest. Reconnect to resume."
        case .checksumVerificationFailed(let count):
            return "\(count) file(s) failed checksum verification."
        }
    }
}
