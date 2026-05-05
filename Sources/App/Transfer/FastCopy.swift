// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import CTransferUtils
import SnapHaulKit

// MARK: - Fast File Copy

/// Direct I/O file copy with page-aligned buffers, bypassing macOS buffer cache.
enum FastCopy {

    /// Copy a file with F_NOCACHE + F_PREALLOCATE + F_FULLFSYNC.
    /// Creates parent directories if needed.
    static func copy(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 0
    ) throws -> UInt64 {
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var bytesWritten: UInt64 = 0
        let result = fast_copy_nocache(
            source.path,
            destination.path,
            chunkSize,
            &bytesWritten
        )
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return bytesWritten
    }
}

// MARK: - Fast ls Parser

/// Parses `ls -la` output via C pointer arithmetic — 3–10x faster than Swift
/// string splitting for directories with 100+ files.
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

    /// Re-enable Spotlight for many files. Uses withCString once per URL
    /// to minimize bridging overhead.
    static func enableBatch(urls: [URL]) {
        for url in urls {
            url.path.withCString { path in
                _ = enable_spotlight(path)
            }
        }
    }
}

// MARK: - XXH3 Hashing

/// Memory-mapped XXH3-64 hashing. ~15–30 GB/s on Apple Silicon.
enum FastXXH3 {

    /// Hash a file and return a 16-char hex string.
    static func hashFile(at url: URL) throws -> String {
        var hash: UInt64 = 0
        let result = xxh3_hash_file(url.path, &hash)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return formatHash(hash)
    }

    /// Hash in-memory data and return a 16-char hex string.
    static func hash(data: Data) -> String {
        guard !data.isEmpty else { return formatHash(0) }
        let hash = data.withUnsafeBytes { ptr in
            xxh3_hash_buffer(ptr.baseAddress!, ptr.count)
        }
        return formatHash(hash)
    }

    /// Hash raw bytes.
    static func hash(bytes: UnsafeRawBufferPointer) -> UInt64 {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
        return xxh3_hash_buffer(base, bytes.count)
    }

    private static func formatHash(_ hash: UInt64) -> String {
        var buf = [CChar](repeating: 0, count: 17)
        xxh3_format_hex(hash, &buf)
        return String(cString: buf)
    }
}

// MARK: - Fast EXIF Date

/// Extracts DateTimeOriginal by reading only the first 64 KB of the file.
/// 100x faster than CGImageSource when you only need the capture date.
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

        var formattedDate: String {
            String(format: "%04d%02d%02d", year, month, day)
        }

        var formattedTime: String {
            String(format: "%02d%02d%02d", hour, minute, second)
        }

        /// "YYYY-MM-DD" for naming templates.
        var isoDate: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    /// Extract capture date. Returns nil for non-image files or missing EXIF.
    static func extractDate(from url: URL) -> DateResult? {
        var result = exif_date_t()
        guard fast_exif_date(url.path, &result) == 0, result.valid != 0 else {
            return nil
        }
        return DateResult(
            year: Int(result.year), month: Int(result.month), day: Int(result.day),
            hour: Int(result.hour), minute: Int(result.minute), second: Int(result.second)
        )
    }

    /// Check if a file likely has EXIF data based on extension.
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
        guard output.withCString({ parse_adb_pull_output($0, &result) }) == 0 else {
            return nil
        }
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
        guard output.withCString({ parse_df_output($0, &total, &free) }) == 0 else {
            return nil
        }
        return (total: total, free: free)
    }
}
