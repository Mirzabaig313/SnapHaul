// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import CTransferUtils
import SnapHaulKit

/// Swift wrapper over the C `fast_copy_nocache` function.
///
/// Copies a file using direct I/O with page-aligned buffers, bypassing
/// the macOS buffer cache. 10–30% faster than `FileManager.copyItem`
/// for large files, and frees hundreds of MB of buffer cache pressure.
enum FastCopy {

    /// Copy a file with F_NOCACHE on both source and destination.
    ///
    /// - Parameters:
    ///   - source: Source file URL
    ///   - destination: Destination file URL (created or overwritten)
    ///   - chunkSize: I/O chunk size (0 = auto 4 MB, auto-aligned to page size)
    /// - Returns: Total bytes written
    /// - Throws: `POSIXError` on failure
    static func copy(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 0
    ) throws -> UInt64 {
        var bytesWritten: UInt64 = 0

        let result = fast_copy_nocache(
            source.path,
            destination.path,
            chunkSize,
            &bytesWritten
        )

        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return bytesWritten
    }
}

/// Swift wrapper over the C `parse_ls_output` function.
///
/// Parses `ls -la` output 3–10x faster than Swift string splitting
/// for directories with thousands of files.
enum FastLsParser {

    /// Parse `ls -la` output into FileItem array.
    ///
    /// - Parameters:
    ///   - output: Raw `ls -la` output string from ADB
    ///   - parentPath: Parent directory path on the device
    /// - Returns: Array of parsed file items
    static func parse(output: String, parentPath: String) -> [FileItem] {
        // Estimate entry count from newline count (avoid 30 MB over-allocation)
        let estimatedLines = output.utf8.lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1
        let maxEntries = min(estimatedLines, 10_000)
        var entries = [ls_entry_t](repeating: ls_entry_t(), count: maxEntries)

        let count = output.withCString { outputPtr in
            parentPath.withCString { parentPtr in
                parse_ls_output(outputPtr, parentPtr, &entries, Int32(maxEntries))
            }
        }

        guard count > 0 else { return [] }

        var items: [FileItem] = []
        items.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let entry = entries[i]

            let name = withUnsafePointer(to: entry.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 1024) {
                    String(cString: $0)
                }
            }

            let path = withUnsafePointer(to: entry.path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 2048) {
                    String(cString: $0)
                }
            }

            let modDate = Date(timeIntervalSince1970: TimeInterval(entry.mod_time))
            let isDir = entry.is_directory != 0

            let contentType: String
            if isDir {
                contentType = "public.folder"
            } else {
                contentType = FileTypeRegistry.utTypeString(for: name)
            }

            items.append(FileItem(
                id: path,
                name: name,
                path: path,
                isDirectory: isDir,
                size: isDir ? 0 as UInt64 : entry.size,
                modificationDate: modDate,
                contentType: contentType
            ))
        }

        return items
    }
}

/// Swift wrapper over C Spotlight xattr functions.
enum SpotlightControl {

    static func suppress(at url: URL) {
        _ = suppress_spotlight(url.path)
    }

    static func enable(at url: URL) {
        _ = enable_spotlight(url.path)
    }

    static func enableBatch(urls: [URL]) {
        for url in urls {
            _ = enable_spotlight(url.path)
        }
    }
}
