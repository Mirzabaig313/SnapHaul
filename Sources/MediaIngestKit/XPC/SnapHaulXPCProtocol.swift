// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// XPC protocol for communication between the host app and extensions
/// (File Provider, Finder Sync).
///
/// Extensions are stateless clients. All device state and transfer logic
/// lives in the host app process. Extensions call these methods via
/// `NSXPCConnection` to request data or trigger actions.
///
/// All reply blocks are called on an arbitrary queue — callers must
/// dispatch to the main queue if they need to update UI.
@objc public protocol SnapHaulXPCProtocol {

    // MARK: - Device Status

    /// Get the current device connection state.
    /// Reply: JSON-encoded `DeviceState`, or nil if no device is connected.
    func deviceStatus(reply: @escaping (Data?, Error?) -> Void)

    // MARK: - File Operations (Device ↔ Mac)

    /// List files at the given path on the connected Android device.
    /// Reply: JSON-encoded `[FileItem]`.
    func listFiles(at path: String, reply: @escaping (Data?, Error?) -> Void)

    /// Pull a file from the device and write it to a local path on the Mac.
    /// Reply: bytes written, or error.
    func pullFile(
        from remotePath: String,
        to localPath: String,
        reply: @escaping (UInt64, Error?) -> Void
    )

    /// Push a file from the Mac to the device.
    /// Reply: success flag, or error.
    func pushFile(
        from localPath: String,
        to remotePath: String,
        reply: @escaping (Bool, Error?) -> Void
    )

    /// Delete a file on the device.
    func deleteFile(at path: String, reply: @escaping (Bool, Error?) -> Void)

    /// Rename a file on the device (same directory, new filename only).
    func renameFile(at path: String, to newName: String, reply: @escaping (Bool, Error?) -> Void)

    // MARK: - Transfer Progress

    /// Get the current transfer progress.
    /// Reply: JSON-encoded `TransferProgress`, or nil if no transfer is active.
    func transferProgress(reply: @escaping (Data?, Error?) -> Void)

    // MARK: - Checksum

    /// Compute the SHA-256 checksum of a local Mac file.
    /// Used by Finder Sync "Verify Checksum Against Android".
    func checksumLocalFile(at localPath: String, reply: @escaping (String?, Error?) -> Void)
}
