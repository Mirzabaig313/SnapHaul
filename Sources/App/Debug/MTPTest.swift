// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

#if DEBUG
import Foundation
import SnapHaulKit
import CLibMTP
import os

/// Standalone test for MTP device connectivity and file transfer.
///
/// Run from the command line to verify libmtp integration works:
/// ```
/// swift build && .build/debug/SnapHaul --test-mtp
/// ```
///
/// Connect an Android phone in MTP (File Transfer) mode before running.
/// The test will list root files and optionally transfer a small file.
enum MTPTest {

    /// MTP uses 0xFFFFFFFF as the parent ID for the storage root.
    private static let rootParentID: UInt32 = 0xFFFF_FFFF

    static func run() {
        let logger = Logger(subsystem: "com.snaphaul.app", category: "test")
        logger.info("Starting MTP test — ensure your Android device is connected in MTP mode...")

        print("╔══════════════════════════════════════════════════╗")
        print("║  SnapHaul MTP Test                              ║")
        print("║  Ensure your Android device is connected        ║")
        print("║  and set to File Transfer (MTP) mode.           ║")
        print("╚══════════════════════════════════════════════════╝")
        print()

        // Initialize libmtp.
        LIBMTP_Init()
        print("✓ libmtp initialized")

        // Detect raw devices.
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var numDevices: CInt = 0
        let detectResult = LIBMTP_Detect_Raw_Devices(&rawDevices, &numDevices)

        guard detectResult == LIBMTP_ERROR_NONE,
              let devices = rawDevices,
              numDevices > 0 else {
            print("✗ No MTP devices found (error code: \(detectResult.rawValue))")
            print()
            print("Troubleshooting:")
            print("  1. Is your phone connected via USB?")
            print("  2. Is it set to 'File Transfer' / MTP mode?")
            print("  3. Is the screen unlocked?")
            exit(1)
        }

        print("✓ Found \(numDevices) raw MTP device(s)")
        print()

        // Open the first device.
        guard let mtpDevice = LIBMTP_Open_Raw_Device_Uncached(&devices[0]) else {
            print("✗ Failed to open MTP session with device")
            free(rawDevices)
            exit(1)
        }
        defer {
            LIBMTP_Release_Device(mtpDevice)
            free(rawDevices)
        }

        print("✓ MTP session opened")

        // Print device info.
        printDeviceInfo(mtpDevice)

        // Get storage.
        let storageResult = LIBMTP_Get_Storage(mtpDevice, LIBMTP_STORAGE_SORTBY_NOTSORTED)
        guard storageResult == 0, let storage = mtpDevice.pointee.storage else {
            print("✗ Could not retrieve storage info")
            exit(1)
        }

        let storageID = storage.pointee.id
        let storageName = storage.pointee.StorageDescription
            .flatMap { String(cString: $0) } ?? "unnamed"
        let totalGB = Double(storage.pointee.MaxCapacity) / 1_073_741_824
        let freeGB = Double(storage.pointee.FreeSpaceInBytes) / 1_073_741_824

        print()
        print("📦 Storage: \(storageName)")
        print("   Total:   \(String(format: "%.1f", totalGB)) GB")
        print("   Free:    \(String(format: "%.1f", freeGB)) GB")
        print()

        // List files at root.
        print("📂 Root directory listing:")
        print("   ─────────────────────────────────────────────")

        let rootFiles = LIBMTP_Get_Files_And_Folders(
            mtpDevice,
            storageID,
            rootParentID
        )

        var node = rootFiles
        var fileCount = 0
        var firstSmallFile: (id: UInt32, name: String, size: UInt64)?

        while let current = node {
            let file = current.pointee
            let name = file.filename.flatMap { String(cString: $0) } ?? "?"
            let isDir = file.filetype == LIBMTP_FILETYPE_FOLDER
            let icon = isDir ? "📁" : "📄"
            let sizeStr = isDir ? "" : " (\(ByteFormatter.format(file.filesize)))"

            print("   \(icon) \(name)\(sizeStr)")
            fileCount += 1

            // Track the first small file (<1 MB) for transfer test.
            if firstSmallFile == nil && !isDir && file.filesize > 0 && file.filesize < 1_048_576 {
                firstSmallFile = (id: file.item_id, name: name, size: file.filesize)
            }

            let next = current.pointee.next
            LIBMTP_destroy_file_t(current)
            node = next
        }

        print("   ─────────────────────────────────────────────")
        print("   \(fileCount) item(s)")
        print()

        // Transfer test — pull the first small file to /tmp.
        if let target = firstSmallFile {
            print("📥 Transfer test: \(target.name) (\(ByteFormatter.format(target.size)))")

            let destPath = "/tmp/snaphaul-mtp-test-\(target.name)"
            let result = LIBMTP_Get_File_To_File(
                mtpDevice,
                target.id,
                destPath,
                nil,
                nil
            )

            if result == 0 {
                print("   ✓ Transferred to \(destPath)")

                // Verify the file size matches.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: destPath),
                   let localSize = attrs[.size] as? UInt64 {
                    if localSize == target.size {
                        print("   ✓ Size verified: \(ByteFormatter.format(localSize))")
                    } else {
                        print("   ⚠ Size mismatch: expected \(target.size), got \(localSize)")
                    }
                }

                // Clean up.
                try? FileManager.default.removeItem(atPath: destPath)
                print("   ✓ Temp file cleaned up")
            } else {
                print("   ✗ Transfer failed")
                printMTPErrors(mtpDevice)
            }
        } else {
            print("ℹ No small files (<1 MB) at root to test transfer.")
            print("  This is normal — most phones store files in subdirectories.")
        }

        print()
        print("✓ MTP test complete")
        exit(0)
    }

    // MARK: - Helpers

    private static func printDeviceInfo(
        _ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>
    ) {
        let model = extractCString(LIBMTP_Get_Modelname(dev)) ?? "unknown"
        let manufacturer = extractCString(LIBMTP_Get_Manufacturername(dev)) ?? "unknown"
        let serial = extractCString(LIBMTP_Get_Serialnumber(dev)) ?? "unknown"
        let redactedSerial = serial.count > 4
            ? "***" + String(serial.suffix(4))
            : "****"

        print()
        print("📱 Device Info:")
        print("   Model:        \(model)")
        print("   Manufacturer: \(manufacturer)")
        print("   Serial:       \(redactedSerial)")
    }

    private static func printMTPErrors(
        _ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>
    ) {
        var errNode = LIBMTP_Get_Errorstack(dev)
        while let err = errNode {
            if let text = err.pointee.error_text {
                print("   MTP error: \(String(cString: text))")
            }
            errNode = err.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
    }

    private static func extractCString(
        _ cStr: UnsafeMutablePointer<CChar>?
    ) -> String? {
        guard let ptr = cStr else { return nil }
        let str = String(cString: ptr)
        free(ptr)
        return str
    }
}
#endif
