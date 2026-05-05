// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit

/// Protocol that both MTP and ADB engines conform to.
///
/// The Transfer Coordinator works against this protocol, never a concrete type.
/// This allows engine swapping at runtime based on device state and user preference.
protocol TransferEngine: Sendable {

    /// Connect to the given USB device.
    func connect(device: USBDevice) async throws

    /// Disconnect from the current device.
    func disconnect() async

    /// Whether the engine is currently connected to a device.
    var isConnected: Bool { get async }

    /// List files and directories at the given path on the device.
    func listFiles(at path: String) async throws -> [FileItem]

    /// Read file contents from the device into memory.
    ///
    /// Use only for small files (<10 MB). For large files, use `pullFile(from:to:)`.
    func readFile(at path: String, offset: UInt64, length: UInt64) async throws -> Data

    /// Pull a file from the device directly to a local destination.
    ///
    /// This is the preferred transfer method — writes directly to disk
    /// without loading the entire file into memory. Supports files of any size.
    ///
    /// - Parameters:
    ///   - remotePath: File path on the device.
    ///   - localURL: Destination URL on the Mac.
    ///   - progress: Called periodically with bytes transferred so far.
    /// - Returns: Total bytes written.
    func pullFile(
        from remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UInt64

    /// Write data to a file on the device.
    func writeFile(at path: String, data: Data) async throws

    /// Delete a file on the device.
    func deleteFile(at path: String) async throws

    /// Rename or move a file on the device.
    ///
    /// - Parameters:
    ///   - path: Current full path of the file on the device.
    ///   - newName: New filename only (not a full path). The file stays
    ///     in the same directory.
    func renameFile(at path: String, to newName: String) async throws

    /// Get device information (model, serial, storage).
    func deviceInfo() async throws -> DeviceState

    /// Compute a checksum of a file on the device (if supported).
    /// Returns nil if the engine cannot compute checksums on-device.
    func remoteChecksum(at path: String, algorithm: ChecksumAlgorithm) async throws -> String?
}

/// Supported checksum algorithms.
enum ChecksumAlgorithm: String, Sendable {
    case xxh3
    case sha256
}
