// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation


///
/// Minimum supported: Android 10+ (API 29). Devices below Android 10 are not supported.

enum DeviceQuirks {

    // MARK: - Quirk Flags

    struct QuirkSet: OptionSet, Sendable {
        let rawValue: UInt32

        /// Samsung: GetPartialObject fails when (file_size % 512) == 500 and read reaches EOF.
        /// Workaround: read one fewer byte, then issue a 1-byte follow-up read.
        static let samsungPartialObjectBug = QuirkSet(rawValue: 1 << 0)

        /// Device closes MTP session faster than spec (< 30s idle).
        /// Workaround: reduce keep-alive interval.
        static let shortIdleTimeout = QuirkSet(rawValue: 1 << 1)

        /// MTP enumeration is extremely slow (>10s for 1000 files).
        /// Workaround: prefer ADB engine, cache aggressively.
        static let slowEnumeration = QuirkSet(rawValue: 1 << 2)

        /// ADB should be the recommended engine for this device.
        static let preferADB = QuirkSet(rawValue: 1 << 3)

        /// Device takes >5s to respond to OpenSession.
        /// Workaround: increase connection timeout to 15s.
        static let highConnectionLatency = QuirkSet(rawValue: 1 << 4)

        /// Screen lock kills USB connection mid-transfer without graceful close.
        /// Workaround: warn user to keep device awake, implement resume-on-reconnect.
        static let screenLockKillsUSB = QuirkSet(rawValue: 1 << 5)

        /// Device does not support GetPartialObject64 (0x95C1).
        /// Workaround: use full GetObject for all reads, never partial.
        static let noPartialObject64 = QuirkSet(rawValue: 1 << 6)

        /// Samsung: GetObjectHandles fails at directory sizes of 128*i - 4 (124, 252, 380...).
        /// Workaround: retry with format filter, or enumerate in smaller batches.
        static let objectCountBoundaryBug = QuirkSet(rawValue: 1 << 7)

        /// Device uses custom (non-AOSP) MTP stack with non-standard behavior.
        static let customMTPStack = QuirkSet(rawValue: 1 << 8)

        /// MTP transfer speed is artificially capped (~6 MB/s even on USB 3.x).
        /// Workaround: prefer ADB which bypasses the MTP speed limit.
        static let throttledMTPSpeed = QuirkSet(rawValue: 1 << 9)

        /// Device returns GENERAL_ERROR instead of SESSION_ALREADY_OPEN on duplicate OpenSession.
        /// Workaround: treat GENERAL_ERROR during OpenSession as recoverable.
        static let generalErrorOnDuplicateSession = QuirkSet(rawValue: 1 << 10)
    }

    // MARK: - Device Profile

    struct DeviceProfile: Sendable {
        let vendorName: String
        let quirks: QuirkSet
        let keepAliveInterval: UInt  // seconds (0 = use default 15s)
        let connectionTimeout: UInt  // seconds (0 = use default 5s)
        let interOpDelay: UInt       // milliseconds between MTP operations (0 = none)
    }

    // MARK: - Vendor IDs

    private static let vendorSamsung: UInt16 = 0x04E8
    private static let vendorGoogle: UInt16 = 0x18D1
    private static let vendorXiaomi: UInt16 = 0x2717
    private static let vendorOnePlus: UInt16 = 0x22D9
    private static let vendorOppo: UInt16 = 0x2A70
    private static let vendorMotorola: UInt16 = 0x22B8
    private static let vendorSony: UInt16 = 0x0FCE
    private static let vendorHuawei: UInt16 = 0x12D1
    private static let vendorNothing: UInt16 = 0x2970

    // MARK: - Profiles

    private static let profiles: [UInt16: DeviceProfile] = [
        vendorSamsung: DeviceProfile(
            vendorName: "Samsung",
            quirks: [.samsungPartialObjectBug, .shortIdleTimeout, .customMTPStack,
                     .objectCountBoundaryBug],
            keepAliveInterval: 10,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorGoogle: DeviceProfile(
            vendorName: "Google",
            quirks: [],  // AOSP reference — most compliant
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorXiaomi: DeviceProfile(
            vendorName: "Xiaomi",
            quirks: [.slowEnumeration, .preferADB, .throttledMTPSpeed,
                     .generalErrorOnDuplicateSession],
            keepAliveInterval: 12,
            connectionTimeout: 10,
            interOpDelay: 30
        ),
        vendorOnePlus: DeviceProfile(
            vendorName: "OnePlus",
            quirks: [.highConnectionLatency],
            keepAliveInterval: 0,
            connectionTimeout: 15,
            interOpDelay: 0
        ),
        vendorOppo: DeviceProfile(
            vendorName: "Oppo",
            quirks: [.highConnectionLatency],
            keepAliveInterval: 0,
            connectionTimeout: 15,
            interOpDelay: 0
        ),
        vendorMotorola: DeviceProfile(
            vendorName: "Motorola",
            quirks: [.screenLockKillsUSB],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorSony: DeviceProfile(
            vendorName: "Sony",
            quirks: [.noPartialObject64],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorHuawei: DeviceProfile(
            vendorName: "Huawei",
            quirks: [.slowEnumeration, .preferADB],
            keepAliveInterval: 12,
            connectionTimeout: 10,
            interOpDelay: 20
        ),
        vendorNothing: DeviceProfile(
            vendorName: "Nothing",
            quirks: [],  // Uses AOSP stack
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
    ]

    /// Default profile for unknown vendors — assumes AOSP-compliant behavior.
    private static let defaultProfile = DeviceProfile(
        vendorName: "Unknown",
        quirks: [],
        keepAliveInterval: 0,
        connectionTimeout: 0,
        interOpDelay: 0
    )

    // MARK: - Public API

    /// Get the device profile for a given vendor ID.
    static func profile(for vendorID: UInt16) -> DeviceProfile {
        profiles[vendorID] ?? defaultProfile
    }

    /// Check if a specific quirk applies to this vendor.
    static func hasQuirk(_ quirk: QuirkSet, vendorID: UInt16) -> Bool {
        let p = profile(for: vendorID)
        return p.quirks.contains(quirk)
    }

    /// Get the recommended keep-alive interval for this device (seconds).
    /// Returns the default (15s) if no vendor-specific override.
    static func keepAliveInterval(for vendorID: UInt16) -> UInt {
        let interval = profile(for: vendorID).keepAliveInterval
        return interval > 0 ? interval : 15
    }

    /// Get the recommended connection timeout for this device (seconds).
    /// Returns the default (5s) if no vendor-specific override.
    static func connectionTimeout(for vendorID: UInt16) -> UInt {
        let timeout = profile(for: vendorID).connectionTimeout
        return timeout > 0 ? timeout : 5
    }

    /// Whether ADB should be recommended over MTP for this device.
    static func shouldPreferADB(vendorID: UInt16) -> Bool {
        hasQuirk(.preferADB, vendorID: vendorID)
    }

    /// Whether GetPartialObject should be avoided for this device.
    static func shouldAvoidPartialObject(vendorID: UInt16) -> Bool {
        hasQuirk(.noPartialObject64, vendorID: vendorID)
    }

    // MARK: - Samsung-Specific

    /// Check if a file triggers Samsung's GetPartialObject 512-byte boundary bug.
    /// Bug condition: (file_size % 512) == 500 AND the read reaches EOF.
    /// Returns the safe read length (1 byte shorter) if the bug would trigger.
    static func samsungSafePartialReadLength(fileSize: UInt64, offset: UInt64, requestedLength: UInt64) -> UInt64? {
        let endOffset = offset + requestedLength
        guard endOffset >= fileSize else { return nil }  // Not reading to EOF — safe

        let remainder = fileSize % 512
        guard remainder == 500 else { return nil }  // Not the bug condition — safe

        // Bug would trigger: return length - 1 (caller must issue a follow-up 1-byte read)
        return requestedLength > 1 ? requestedLength - 1 : nil
    }
}
