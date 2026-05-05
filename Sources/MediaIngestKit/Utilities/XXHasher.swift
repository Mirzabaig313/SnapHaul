// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import xxHash_Swift

/// Fast non-cryptographic file hasher using XXH3-128.
///
/// Designed for delta-sync checksum verification. Uses memory-mapped reads
/// to avoid allocating a separate read buffer — the kernel pages in only
/// what the hash function touches.
///
/// For cryptographic verification (forensics), use `SHA256Hasher` instead.
public enum XXHasher {

    /// Compute XXH64 hash of a file at the given URL.
    ///
    /// Uses memory-mapped I/O for zero-copy hashing.
    /// - Parameter url: Local file URL to hash.
    /// - Returns: Hex string of the 64-bit hash.
    public static func hashFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = xxHash64.digest(data)
        return String(format: "%016llx", hash)
    }

    /// Compute XXH64 hash of raw data.
    public static func hash(data: Data) -> String {
        let hash = xxHash64.digest(data)
        return String(format: "%016llx", hash)
    }
}
