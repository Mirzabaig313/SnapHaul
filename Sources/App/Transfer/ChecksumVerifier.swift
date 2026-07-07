// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
internal import CryptoKit
import os

/// Verifies file integrity after transfer by comparing checksums.
///
/// Uses memory-mapped reads for the local file to avoid allocating
/// a separate read buffer.
struct ChecksumVerifier {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "checksum"
    )

    /// Verify a transferred file against its source.
    ///
    /// - Parameters:
    ///   - localURL: Path to the transferred file on the Mac.
    ///   - remotePath: Path to the source file on the Android device.
    ///   - engine: Transfer engine for remote checksum (ADB) or re-read (MTP).
    ///   - algorithm: Hash algorithm to use.
    /// - Returns: `true` if checksums match, `false` otherwise.
    func verify(
        localURL: URL,
        remotePath: String,
        engine: any TransferEngine,
        algorithm: ChecksumAlgorithm = .xxh3
    ) async throws -> Bool {
        let localHash = try hashLocalFile(at: localURL, algorithm: algorithm)

        if let remoteHash = try await engine.remoteChecksum(at: remotePath, algorithm: algorithm) {
            let match = localHash == remoteHash
            if !match {
                logger.error(
                    "Checksum mismatch: local=\(localHash) remote=\(remoteHash) file=\(localURL.lastPathComponent, privacy: .private(mask: .hash))"
                )
            }
            return match
        }

        // Fallback: pull the file again and hash locally
        // This is expensive but necessary for MTP (no remote hash capability)
        logger.debug("No remote checksum available, re-reading file for verification")
        let remoteData = try await engine.readFile(at: remotePath, offset: 0, length: UInt64.max)
        let remoteHash: String
        switch algorithm {
        case .xxh3:
            remoteHash = FastXXH3.hash(data: remoteData)
        case .sha256:
            remoteHash = sha256Hash(data: remoteData)
        }

        let match = localHash == remoteHash
        if !match {
            logger.error(
                "Checksum mismatch (re-read): local=\(localHash) remote=\(remoteHash)"
            )
        }
        return match
    }

    /// Hash a local file using memory-mapped I/O.
    private func hashLocalFile(at url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        switch algorithm {
        case .xxh3:
            return try FastXXH3.hashFile(at: url)
        case .sha256:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return sha256Hash(data: data)
        }
    }

    /// Compute SHA-256 hash of data.
    private func sha256Hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
