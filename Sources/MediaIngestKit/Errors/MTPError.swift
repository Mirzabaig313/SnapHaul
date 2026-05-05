// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Errors originating from the MTP transfer engine.
public enum MTPError: Error, LocalizedError, Sendable {

    case connectionFailed(device: String, reason: String)
    case sessionRejected(device: String)
    case deviceNotFound
    case deviceLocked(device: String)
    case transferTimeout(file: String, bytesTransferred: UInt64)
    case transferFailed(file: String, reason: String)
    case checksumMismatch(file: String, expected: String, actual: String)
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case storageFullOnDevice
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let device, let reason):
            return "Failed to connect to \(device): \(reason)"
        case .sessionRejected(let device):
            return "MTP session rejected by \(device). The device may be locked."
        case .deviceNotFound:
            return "No MTP device found. Ensure the device is connected and set to File Transfer mode."
        case .deviceLocked(let device):
            return "Please unlock \(device) and try again."
        case .transferTimeout(let file, let bytes):
            return "Transfer timed out for \(file) after \(bytes) bytes."
        case .transferFailed(let file, let reason):
            return "Transfer failed for \(file): \(reason)"
        case .checksumMismatch(let file, _, _):
            return "Checksum mismatch for \(file). The file may be corrupted."
        case .fileNotFound(let path):
            return "File not found on device: \(path)"
        case .permissionDenied(let path):
            return "Permission denied for: \(path)"
        case .storageFullOnDevice:
            return "Device storage is full."
        case .unsupportedOperation(let op):
            return "Unsupported MTP operation: \(op)"
        }
    }
}
