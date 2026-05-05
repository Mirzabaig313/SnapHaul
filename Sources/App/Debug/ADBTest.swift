// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

#if DEBUG
import Foundation
import SnapHaulKit
import os

/// Standalone test for ADB device connectivity and file listing.
///
/// Run from the command line:
/// ```
/// swift build && .build/debug/SnapHaul --test-adb
/// ```
///
/// Requires USB Debugging enabled on the Android device.
enum ADBTest {

    static func run() {
        let logger = Logger(subsystem: "com.snaphaul.app", category: "test")
        logger.info("Starting ADB test...")

        print("╔══════════════════════════════════════════════════╗")
        print("║  SnapHaul ADB Test                              ║")
        print("║  Ensure USB Debugging is enabled on your device ║")
        print("╚══════════════════════════════════════════════════╝")
        print()

        // Find adb
        let adbPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let adbPath = adbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("✗ ADB not found. Install via: brew install android-platform-tools")
            exit(1)
        }
        print("✓ ADB found at \(adbPath)")

        // Run the async test
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let engine = ADBEngine()

                // Create a dummy USB device for connection
                let device = USBDevice(
                    serialNumber: "auto",
                    vendorID: 0,
                    productID: 0,
                    displayName: "ADB Device",
                    manufacturer: "Unknown",
                    usbMode: .adb,
                    usbSpeed: .unknown
                )

                try await engine.connect(device: device)
                print("✓ ADB connection established")

                // Get device info
                let info = try await engine.deviceInfo()
                print()
                print("📱 Device Info:")
                print("   Model:        \(info.displayName)")
                print("   Manufacturer: \(info.manufacturer)")
                print("   Serial:       \(info.redactedSerial)")
                if let total = info.storageTotal, let free = info.storageFree {
                    let totalGB = Double(total) / 1_073_741_824
                    let freeGB = Double(free) / 1_073_741_824
                    print("   Storage:      \(String(format: "%.1f", freeGB)) GB free / \(String(format: "%.1f", totalGB)) GB total")
                }
                print()

                // List root files
                print("📂 Root directory listing:")
                print("   ─────────────────────────────────────────────")

                let files = try await engine.listFiles(at: "/sdcard")
                for file in files.prefix(20) {
                    let icon = file.isDirectory ? "📁" : "📄"
                    let sizeStr = file.isDirectory ? "" : " (\(ByteFormatter.format(file.size)))"
                    print("   \(icon) \(file.name)\(sizeStr)")
                }
                if files.count > 20 {
                    print("   ... and \(files.count - 20) more")
                }
                print("   ─────────────────────────────────────────────")
                print("   \(files.count) item(s)")
                print()

                // List DCIM if it exists
                let dcimFiles = try? await engine.listFiles(at: "/sdcard/DCIM/Camera")
                if let dcim = dcimFiles, !dcim.isEmpty {
                    print("📸 DCIM/Camera: \(dcim.count) items")
                    for file in dcim.prefix(5) {
                        let sizeStr = file.isDirectory ? "" : " (\(ByteFormatter.format(file.size)))"
                        print("   📄 \(file.name)\(sizeStr)")
                    }
                    if dcim.count > 5 {
                        print("   ... and \(dcim.count - 5) more")
                    }
                    print()

                    // Transfer test — pull first small file
                    if let target = dcim.first(where: { !$0.isDirectory && $0.size > 0 && $0.size < 5_000_000 }) {
                        print("📥 Transfer test: \(target.name) (\(ByteFormatter.format(target.size)))")
                        let destURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("snaphaul-adb-test-\(target.name)")
                        defer { try? FileManager.default.removeItem(at: destURL) }

                        let startTime = Date()
                        let bytes = try await engine.pullFile(from: target.path, to: destURL, progress: nil)
                        let elapsed = Date().timeIntervalSince(startTime)
                        let speed = elapsed > 0 ? Double(bytes) / elapsed / 1_000_000 : 0

                        print("   ✓ Transferred \(ByteFormatter.format(bytes)) in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", speed)) MB/s)")
                        print("   ✓ Temp file cleaned up")
                    }
                }

                await engine.disconnect()
                print("✓ ADB test complete")

            } catch {
                print("✗ ADB test failed: \(error.localizedDescription)")
                if let adbErr = error as? ADBError {
                    switch adbErr {
                    case .deviceNotAuthorized:
                        print()
                        print("Troubleshooting:")
                        print("  1. Check your phone screen for a USB debugging authorization prompt")
                        print("  2. Tap 'Allow' on the device")
                        print("  3. Run this test again")
                    case .deviceOffline:
                        print()
                        print("Troubleshooting:")
                        print("  1. Enable USB Debugging: Settings → Developer Options → USB Debugging")
                        print("  2. Reconnect the USB cable")
                        print("  3. Run this test again")
                    default:
                        break
                    }
                }
            }

            semaphore.signal()
        }

        semaphore.wait()
        exit(0)
    }
}
#endif
