// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

#if DEBUG
import Foundation
import SnapHaulKit
import os

/// Standalone test for USB device monitoring.
///
/// Run from the command line to verify IOKit detection works:
/// ```
/// swift build && .build/debug/SnapHaul --test-usb
/// ```
///
/// Then plug in your Android phone. You should see a log message
/// with the device name, manufacturer, vendor ID, USB mode, and speed.
enum USBMonitorTest {

    static func run() {
        let logger = Logger(subsystem: "com.snaphaul.app", category: "test")
        logger.info("Starting USB monitor test — plug in your Android device...")

        print("╔══════════════════════════════════════════════════╗")
        print("║  SnapHaul USB Monitor Test                      ║")
        print("║  Waiting for Android device...                  ║")
        print("║  Plug in your phone via USB-C                   ║")
        print("║  Press Ctrl+C to exit                           ║")
        print("╚══════════════════════════════════════════════════╝")
        print()

        let monitor = DeviceMonitor()

        monitor.onDeviceConnected = { device in
            print("✅ DEVICE CONNECTED")
            print("   Name:         \(device.displayName)")
            print("   Manufacturer: \(device.manufacturer)")
            print("   Model:        \(device.model)")
            print("   Serial:       \(device.redactedSerial)")
            print("   Engine:       \(device.engineType?.rawValue ?? "unknown")")
            print("   USB Speed:    \(device.usbSpeedDescription ?? "unknown")")
            print("   Status:       \(device.connectionStatus.rawValue)")
            print()
        }

        monitor.onDeviceDisconnected = { serial in
            let redacted = serial.count > 4 ? "***" + String(serial.suffix(4)) : "****"
            print("❌ DEVICE DISCONNECTED [\(redacted)]")
            print()
        }

        monitor.startMonitoring()

        // Keep the process alive
        dispatchMain()
    }
}
#endif
