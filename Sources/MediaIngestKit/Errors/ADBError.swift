// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Errors originating from the ADB transfer engine.
public enum ADBError: Error, LocalizedError, Sendable {

    case binaryNotFound
    case serverConflict(runningVersion: String, requiredVersion: String)
    case deviceNotAuthorized(device: String)
    case deviceOffline(device: String)
    case transferFailed(file: String, reason: String)
    case transferTimeout(file: String, bytesTransferred: UInt64)
    case checksumMismatch(file: String, expected: String, actual: String)
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case fileNotFound(path: String)
    case permissionDenied(path: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "ADB binary not found. Ensure it is bundled or installed."
        case .serverConflict(let running, let required):
            return "ADB server version conflict: running \(running), need \(required). Restart ADB?"
        case .deviceNotAuthorized(let device):
            return "\(device) is not authorized for USB debugging. Check the device screen for an authorization prompt."
        case .deviceOffline(let device):
            return "\(device) is offline. Reconnect the USB cable."
        case .transferFailed(let file, let reason):
            return "ADB transfer failed for \(file): \(reason)"
        case .transferTimeout(let file, let bytes):
            return "ADB transfer timed out for \(file) after \(bytes) bytes."
        case .checksumMismatch(let file, _, _):
            return "Checksum mismatch for \(file). The file may be corrupted."
        case .commandFailed(let cmd, let code, let stderr):
            return "ADB command failed (\(cmd), exit \(code)): \(stderr)"
        case .fileNotFound(let path):
            return "File not found on device: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}
