// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// Selects the optimal transfer engine based on device state and user preference.
///
/// Selection logic:
/// 1. If user prefers ADB and device has USB Debugging → ADB
/// 2. If device is in MTP mode → MTP
/// 3. If device is in PTP mode → MTP (PTP subset)
/// 4. If MTP fails 3 consecutive times → suggest ADB
struct EngineSelector {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "engine-selector"
    )

    /// Select the best engine for the given device.
    func selectEngine(
        for device: USBDevice,
        userPreference: String,
        adbAvailable: Bool
    ) -> any TransferEngine {
        if userPreference == "adb" && adbAvailable {
            logger.info("Selected ADB engine (user preference) for \(device.displayName)")
            return ADBEngine()
        }

        if adbAvailable && userPreference == "auto" && device.usbMode == .adb {
            logger.info("Selected ADB engine (auto, device in ADB mode) for \(device.displayName)")
            return ADBEngine()
        }

        logger.info("Selected MTP engine for \(device.displayName)")
        return MTPEngine()
    }
}
