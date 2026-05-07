// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
internal import xxHash_Swift

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

    /// Compute XXH64 hash as a raw UInt64 for direct comparison without string allocation.
    /// Use this in hot paths where formatting overhead matters (batch verification).
    public static func hashRaw(data: Data) -> UInt64 {
        xxHash64.digest(data)
    }

    /// Compute XXH64 hash of a file as a raw UInt64.
    /// Avoids hex string allocation — use for batch comparisons.
    public static func hashFileRaw(at url: URL) throws -> UInt64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return xxHash64.digest(data)
    }

    /// Combine two 64-bit hashes into a 128-bit value for stronger collision resistance.
    /// Useful when comparing large file sets where 64-bit collision probability matters.
    @available(macOS 15.0, *)
    public static func hash128(data: Data) -> UInt128 {
        let h1 = xxHash64.digest(data, seed: 0)
        let h2 = xxHash64.digest(data, seed: 0x9E37_79B9_7F4A_7C15)
        return UInt128(_low: h1, _high: h2)
    }
}
