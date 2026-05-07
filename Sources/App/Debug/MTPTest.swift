// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

#if DEBUG
import Foundation
import SnapHaulKit
import CMTPCore
import os

/// Standalone test for native MTP device connectivity and file listing.
///
/// Run from the command line:
/// ```
/// swift build && .build/debug/SnapHaul --test-mtp
/// ```
///
/// Connect an Android phone in MTP (File Transfer) mode before running.
/// Tries common Android vendor IDs sequentially until one connects.
enum MTPTest {

    private static let androidVIDs: [(vid: UInt16, pids: [UInt16], name: String)] = [
        (0x2717, [0xFF40, 0xFF48, 0xFF80], "Xiaomi"),
        (0x04E8, [0x6860, 0x6865, 0x6866], "Samsung"),
        (0x18D1, [0x4EE1, 0x4EE2, 0xD001], "Google"),
        (0x22D9, [0x2764, 0x2765], "OnePlus"),
        (0x2A70, [0x9024, 0x9025], "OPPO"),
        (0x22B8, [0x2E82, 0x2E76], "Motorola"),
        (0x0FCE, [0x01A5, 0x51A5], "Sony"),
        (0x2D95, [0x6003, 0x6005], "vivo"),
    ]

    static func run() {
        print("╔══════════════════════════════════════════════════╗")
        print("║  SnapHaul Native MTP Test (CMTPCore + libusb)   ║")
        print("║  Ensure your Android device is connected        ║")
        print("║  and set to File Transfer (MTP) mode.           ║")
        print("╚══════════════════════════════════════════════════╝")
        print()

        // Kill PTPCamera
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["PTPCamera"]
        killTask.standardOutput = FileHandle.nullDevice
        killTask.standardError = FileHandle.nullDevice
        try? killTask.run()
        killTask.waitUntilExit()
        if killTask.terminationStatus == 0 {
            print("✓ Killed PTPCamera daemon")
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Try each VID/PID combination
        var usbInterface = mtp_usb_interface_t()
        var transportCtx: UnsafeMutableRawPointer?
        var connectedVendor = ""

        print("🔍 Scanning for MTP devices...")

        for (vid, pids, name) in androidVIDs {
            for pid in pids {
                let result = mtp_usb_transport_open(vid, pid, &usbInterface, &transportCtx)
                if result == 0 {
                    connectedVendor = name
                    print("✓ Connected to \(name) (VID=\(String(format: "%04x", vid)) PID=\(String(format: "%04x", pid)))")
                    break
                }
                // Clean up failed attempt
                if let ctx = transportCtx {
                    mtp_usb_transport_close(ctx)
                    transportCtx = nil
                }
            }
            if !connectedVendor.isEmpty { break }
        }

        guard !connectedVendor.isEmpty, let tCtx = transportCtx else {
            print("✗ No MTP device found")
            print()
            print("Troubleshooting:")
            print("  1. Is your phone connected via USB?")
            print("  2. Is it set to 'File Transfer' / MTP mode?")
            print("  3. Is the screen unlocked?")
            if let ctx = transportCtx {
                print("  Last error: \(String(cString: mtp_usb_transport_error(ctx)))")
                mtp_usb_transport_close(ctx)
            }
            exit(1)
        }

        // Open MTP session
        guard let session = mtp_session_create(4 * 1024 * 1024, usbInterface) else {
            print("✗ Failed to allocate MTP session")
            mtp_usb_transport_close(tCtx)
            exit(1)
        }

        guard mtp_open_session(session) == 0 else {
            let err = withUnsafeBytes(of: session.pointee.last_error) { buf in
                let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var len = 0
                while len < buf.count && ptr[len] != 0 { len += 1 }
                return String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8) ?? "unknown"
            }
            print("✗ OpenSession failed: \(err)")
            mtp_session_destroy(session)
            mtp_usb_transport_close(tCtx)
            exit(1)
        }
        print("✓ MTP session opened")
        print()

        // Storage info
        let storageCount = mtp_get_storage_ids(session)
        guard storageCount > 0 else {
            print("✗ No storage found")
            _ = mtp_close_session(session)
            mtp_session_destroy(session)
            mtp_usb_transport_close(tCtx)
            exit(1)
        }

        let storageID = session.pointee.storage_ids.0
        var storageInfo = mtp_storage_info_t()
        if mtp_get_storage_info(session, storageID, &storageInfo) == 0 {
            let totalGB = Double(storageInfo.max_capacity) / 1_073_741_824
            let freeGB = Double(storageInfo.free_space) / 1_073_741_824
            print("📦 Storage: \(String(format: "%.1f", totalGB)) GB total, \(String(format: "%.1f", freeGB)) GB free")
        }
        print()

        // List root
        print("📂 Root directory:")
        print("   ─────────────────────────────────────────────")

        var handles = [UInt32](repeating: 0, count: 1000)
        let count = mtp_get_object_handles(session, storageID, 0xFFFFFFFF, 0, &handles, 1000)

        if count > 0 {
            var infos = [mtp_object_info_t](repeating: mtp_object_info_t(), count: Int(count))
            let infoCount = mtp_get_object_info_batch(session, &handles, &infos, count)

            for i in 0..<Int(infoCount) {
                let info = infos[i]
                let name = withUnsafeBytes(of: info.filename) { buf in
                    let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    var len = 0
                    while len < buf.count && ptr[len] != 0 { len += 1 }
                    return String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8) ?? "?"
                }
                let isDir = info.object_format == MTP_FORMAT_ASSOCIATION
                let icon = isDir ? "📁" : "📄"
                let size = isDir ? "" : " (\(ByteFormatter.format(info.object_size_64)))"
                print("   \(icon) \(name)\(size)")
            }
            print("   ─────────────────────────────────────────────")
            print("   \(infoCount) item(s)")
        } else {
            print("   (empty or enumeration failed)")
        }

        // Cleanup
        print()
        _ = mtp_close_session(session)
        mtp_session_destroy(session)
        mtp_usb_transport_close(tCtx)
        print("✓ Native MTP test complete")
        exit(0)
    }
}
#endif
