// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import CTransferUtils
import SnapHaulKit

// MARK: - Fast File Copy

/// Direct I/O file copy with page-aligned buffers, bypassing macOS buffer cache.
/// Uses double-buffering for overlapped read/write.
enum FastCopy {

    /// Copy a file with F_NOCACHE + F_PREALLOCATE + F_FULLFSYNC.
    static func copy(from source: URL, to destination: URL, chunkSize: Int = 0) throws -> UInt64 {
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var bytesWritten: UInt64 = 0
        let result = fast_copy_nocache(source.path, destination.path, chunkSize, &bytesWritten)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return bytesWritten
    }

    /// Copy a file with per-chunk progress reporting.
    /// Safety: pointer to `handler` is valid because fast_copy_with_progress is synchronous.
    static func copyWithProgress(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 0,
        progressHandler: @escaping (UInt64) -> Void
    ) throws -> UInt64 {
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var bytesWritten: UInt64 = 0
        typealias ProgressContext = (UInt64) -> Void
        var handler = progressHandler

        let result = withUnsafeMutablePointer(to: &handler) { ctxPtr in
            fast_copy_with_progress(
                source.path, destination.path, chunkSize, &bytesWritten,
                { bytesSoFar, context in
                    guard let context else { return }
                    context.assumingMemoryBound(to: ProgressContext.self).pointee(bytesSoFar)
                },
                ctxPtr
            )
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return bytesWritten
    }

    /// Copy a file to multiple destinations in parallel using all available cores.
    /// Returns per-destination success/failure.
    static func copyToMultipleDestinations(
        from source: URL,
        to destinations: [URL],
        chunkSize: Int = 0
    ) throws -> [Bool] {
        guard !destinations.isEmpty else { return [] }

        for dest in destinations {
            let parentDir = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var cDstStrings: [UnsafePointer<CChar>?] = destinations.map { UnsafePointer(strdup($0.path)) }
        defer { cDstStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }

        var results = [Int32](repeating: -1, count: destinations.count)

        cDstStrings.withUnsafeMutableBufferPointer { buffer in
            _ = fast_copy_multi_destination(
                source.path,
                buffer.baseAddress!,
                Int32(buffer.count),
                chunkSize,
                &results
            )
        }

        return results.map { $0 == 0 }
    }
}

// MARK: - Fast ls Parser

/// Parses `ls -la` output via C — 3–10x faster than Swift string splitting.
enum FastLsParser {

    static func parse(output: String, parentPath: String) -> [FileItem] {
        let lineCount = output.utf8.lazy.filter { $0 == 0x0A }.count + 1
        let maxEntries = min(lineCount, 10_000)
        var entries = [ls_entry_t](repeating: ls_entry_t(), count: maxEntries)

        let count = output.withCString { outputPtr in
            parentPath.withCString { parentPtr in
                Int(parse_ls_output(outputPtr, parentPtr, &entries, Int32(maxEntries)))
            }
        }
        guard count > 0 else { return [] }

        var items: [FileItem] = []
        items.reserveCapacity(count)

        for i in 0..<count {
            let name = withUnsafeBytes(of: entries[i].name) { buf in
                String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let path = withUnsafeBytes(of: entries[i].path) { buf in
                String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let isDir = entries[i].is_directory != 0
            let contentType = isDir ? "public.folder" : FileTypeRegistry.utTypeString(for: name)

            items.append(FileItem(
                id: path,
                name: name,
                path: path,
                isDirectory: isDir,
                size: isDir ? 0 : entries[i].size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(entries[i].mod_time)),
                contentType: contentType
            ))
        }
        return items
    }
}

// MARK: - Spotlight Control

/// Batch-optimized Spotlight xattr manipulation via C.
enum SpotlightControl {

    static func suppress(at url: URL) {
        _ = suppress_spotlight(url.path)
    }

    static func enable(at url: URL) {
        _ = enable_spotlight(url.path)
    }

    static func enableBatch(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var cStrings: [UnsafePointer<CChar>?] = urls.map { UnsafePointer(strdup($0.path)) }
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = enable_spotlight_batch(buffer.baseAddress!, Int32(buffer.count))
        }
    }

    static func suppressBatch(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var cStrings: [UnsafePointer<CChar>?] = urls.map { UnsafePointer(strdup($0.path)) }
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = suppress_spotlight_batch(buffer.baseAddress!, Int32(buffer.count))
        }
    }
}

// MARK: - XXH3 Hashing

/// Memory-mapped XXH3-64 hashing. ARM NEON vectorized on Apple Silicon.
enum FastXXH3 {

    static func hashFile(at url: URL) throws -> String {
        var hash: UInt64 = 0
        let result = xxh3_hash_file(url.path, &hash)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return formatHash(hash)
    }

    static func hash(data: Data) -> String {
        guard !data.isEmpty else { return formatHash(0) }
        let hash = data.withUnsafeBytes { ptr in
            xxh3_hash_buffer(ptr.baseAddress!, ptr.count)
        }
        return formatHash(hash)
    }

    static func hash(bytes: UnsafeRawBufferPointer) -> UInt64 {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
        return xxh3_hash_buffer(base, bytes.count)
    }

    static func hashFilesBatch(urls: [URL]) -> [String] {
        guard !urls.isEmpty else { return [] }
        var cStrings: [UnsafePointer<CChar>?] = urls.map { UnsafePointer(strdup($0.path)) }
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }

        var hashes = [UInt64](repeating: 0, count: urls.count)
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = xxh3_hash_files_parallel(buffer.baseAddress!, &hashes, Int32(buffer.count))
        }
        return hashes.map { formatHash($0) }
    }

    private static func formatHash(_ hash: UInt64) -> String {
        var buf = [CChar](repeating: 0, count: 17)
        xxh3_format_hex(hash, &buf)
        return String(cString: buf)
    }
}

// MARK: - Fast EXIF Date

/// Extracts DateTimeOriginal from image files by reading only the first 64 KB.
enum FastEXIF {

    struct DateResult: Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        var date: Date? {
            var c = DateComponents()
            c.year = year; c.month = month; c.day = day
            c.hour = hour; c.minute = minute; c.second = second
            return Calendar.current.date(from: c)
        }

        var formattedDate: String { String(format: "%04d%02d%02d", year, month, day) }
        var formattedTime: String { String(format: "%02d%02d%02d", hour, minute, second) }
        var isoDate: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    static func extractDate(from url: URL) -> DateResult? {
        var result = exif_date_t()
        guard fast_exif_date(url.path, &result) == 0, result.valid != 0 else { return nil }
        return DateResult(
            year: Int(result.year), month: Int(result.month), day: Int(result.day),
            hour: Int(result.hour), minute: Int(result.minute), second: Int(result.second)
        )
    }

    static func extractDatesBatch(urls: [URL]) -> [DateResult?] {
        guard !urls.isEmpty else { return [] }
        var cStrings: [UnsafePointer<CChar>?] = urls.map { UnsafePointer(strdup($0.path)) }
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }

        var dates = [exif_date_t](repeating: exif_date_t(), count: urls.count)
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = fast_exif_date_parallel(buffer.baseAddress!, &dates, Int32(buffer.count))
        }

        return dates.map { d in
            guard d.valid != 0 else { return nil }
            return DateResult(
                year: Int(d.year), month: Int(d.month), day: Int(d.day),
                hour: Int(d.hour), minute: Int(d.minute), second: Int(d.second)
            )
        }
    }

    static func supportsEXIF(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "tiff", "tif", "dng", "arw", "cr2", "cr3",
             "nef", "raf", "rw2", "orf", "heic", "heif":
            return true
        default:
            return false
        }
    }
}

// MARK: - ADB Output Tokenizer

/// Zero-allocation C parser for ADB command output.
enum FastADBParser {

    struct PullResult: Sendable {
        let bytesTransferred: UInt64
        let speedMBps: Double
        let durationSecs: Double
        let filesPulled: Int
        let filesSkipped: Int
    }

    struct DeviceInfo: Sendable {
        let serial: String
        let status: String
        let model: String

        var isOnline: Bool { status == "device" }
        var isUnauthorized: Bool { status == "unauthorized" }
    }

    static func parsePullOutput(_ output: String) -> PullResult? {
        var result = adb_pull_result_t()
        guard output.withCString({ parse_adb_pull_output($0, &result) }) == 0 else { return nil }
        return PullResult(
            bytesTransferred: result.bytes_transferred,
            speedMBps: result.speed_mbps,
            durationSecs: result.duration_secs,
            filesPulled: Int(result.files_pulled),
            filesSkipped: Int(result.files_skipped)
        )
    }

    static func parseDevices(_ output: String) -> [DeviceInfo] {
        var devices = [adb_device_t](repeating: adb_device_t(), count: 16)
        let count = output.withCString { ptr in
            Int(parse_adb_devices(ptr, &devices, 16))
        }
        guard count > 0 else { return [] }

        return (0..<count).map { i in
            DeviceInfo(
                serial: withUnsafeBytes(of: devices[i].serial) { buf in
                    String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
                },
                status: withUnsafeBytes(of: devices[i].status) { buf in
                    String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
                },
                model: withUnsafeBytes(of: devices[i].model) { buf in
                    String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
            )
        }
    }

    static func parseDf(_ output: String) -> (total: UInt64, free: UInt64)? {
        var total: UInt64 = 0
        var free: UInt64 = 0
        guard output.withCString({ parse_df_output($0, &total, &free) }) == 0 else { return nil }
        return (total: total, free: free)
    }
}

// MARK: - Buffer Pool

/// Pre-allocated page-aligned buffer pool for transfer chunks.
final class TransferBufferPool: @unchecked Sendable {
    private let pool: UnsafeMutableRawPointer
    let bufferSize: Int

    init?(bufferSize: Int, count: Int = 4) {
        guard let p = buffer_pool_create(bufferSize, Int32(count)) else { return nil }
        self.pool = p
        // Store the actual aligned size (rounded up to 16 KB)
        self.bufferSize = ((bufferSize + 16383) / 16384) * 16384
    }

    deinit { buffer_pool_destroy(pool) }

    func acquire() -> UnsafeMutableRawPointer? {
        buffer_pool_acquire(pool)
    }

    func release(_ buffer: UnsafeMutableRawPointer) {
        buffer_pool_release(pool, buffer)
    }

    /// Scoped buffer access — guarantees release after use.
    func withBuffer<T>(_ body: (UnsafeMutableRawPointer) throws -> T) rethrows -> T? {
        guard let buf = acquire() else { return nil }
        defer { release(buf) }
        return try body(buf)
    }

    /// Hash a file using a pool buffer instead of mmap. Better for many small files.
    func hashFile(at url: URL) throws -> String {
        guard let buf = acquire() else {
            // Pool exhausted — fall back to mmap path
            return try FastXXH3.hashFile(at: url)
        }
        defer { release(buf) }

        var hash: UInt64 = 0
        let result = xxh3_hash_file_pooled(url.path, &hash, buf, bufferSize)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var hexBuf = [CChar](repeating: 0, count: 17)
        xxh3_format_hex(hash, &hexBuf)
        return String(cString: hexBuf)
    }

    /// Copy a file using a pool buffer. Avoids per-file allocation.
    func copyFile(from source: URL, to destination: URL) throws -> UInt64 {
        guard let buf = acquire() else {
            // Pool exhausted — fall back to allocating path
            return try FastCopy.copy(from: source, to: destination)
        }
        defer { release(buf) }

        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var bytesWritten: UInt64 = 0
        let result = fast_copy_pooled(source.path, destination.path, buf, bufferSize, &bytesWritten)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return bytesWritten
    }
}
