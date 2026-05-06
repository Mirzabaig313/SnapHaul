// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

struct EngineSelector {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "engine-selector"
    )

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
            logger.info("Selected ADB engine (device in ADB mode) for \(device.displayName)")
            return ADBEngine()
        }

        if adbAvailable && userPreference == "auto"
            && DeviceQuirks.shouldPreferADB(vendorID: device.vendorID, productName: device.displayName) {
            let profile = DeviceQuirks.profile(for: device.vendorID, productName: device.displayName)
            logger.info("Selected ADB engine (\(profile.vendorName) MTP is slow) for \(device.displayName)")
            return ADBEngine()
        }

        logger.info("Selected native MTP engine for \(device.displayName)")
        return MTPNativeEngine()
    }

    func shouldSuggestADB(for device: USBDevice, adbAvailable: Bool) -> Bool {
        guard !adbAvailable else { return false }
        return DeviceQuirks.shouldPreferADB(vendorID: device.vendorID, productName: device.displayName)
    }
}
