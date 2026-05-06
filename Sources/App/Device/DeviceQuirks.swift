// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Vendor and model-specific MTP quirk profiles for Android 10+ (API 29+) devices.
///
/// Three-tier lookup: vendor defaults → product-string brand detection → model overrides.
enum DeviceQuirks {

    // MARK: - Quirk Flags

    struct QuirkSet: OptionSet, Sendable, CustomStringConvertible {
        let rawValue: UInt32

        static let samsungPartialObjectBug = QuirkSet(rawValue: 1 << 0)
        static let shortIdleTimeout = QuirkSet(rawValue: 1 << 1)
        static let slowEnumeration = QuirkSet(rawValue: 1 << 2)
        static let suggestADB = QuirkSet(rawValue: 1 << 3)
        static let highConnectionLatency = QuirkSet(rawValue: 1 << 4)
        static let customMTPStack = QuirkSet(rawValue: 1 << 5)
        static let throttledMTPSpeed = QuirkSet(rawValue: 1 << 6)
        static let generalErrorOnDuplicateSession = QuirkSet(rawValue: 1 << 7)
        static let scopedStorageSlowdown = QuirkSet(rawValue: 1 << 8)
        static let truncatedObjectInfo = QuirkSet(rawValue: 1 << 9)

        var description: String {
            var names: [String] = []
            if contains(.samsungPartialObjectBug) { names.append("samsungPartialObjectBug") }
            if contains(.shortIdleTimeout) { names.append("shortIdleTimeout") }
            if contains(.slowEnumeration) { names.append("slowEnumeration") }
            if contains(.suggestADB) { names.append("suggestADB") }
            if contains(.highConnectionLatency) { names.append("highConnectionLatency") }
            if contains(.customMTPStack) { names.append("customMTPStack") }
            if contains(.throttledMTPSpeed) { names.append("throttledMTPSpeed") }
            if contains(.generalErrorOnDuplicateSession) { names.append("generalErrorOnDuplicateSession") }
            if contains(.scopedStorageSlowdown) { names.append("scopedStorageSlowdown") }
            if contains(.truncatedObjectInfo) { names.append("truncatedObjectInfo") }
            return names.isEmpty ? "none" : names.joined(separator: ", ")
        }
    }

    // MARK: - Device Profile

    struct DeviceProfile: Sendable {
        let vendorName: String
        let quirks: QuirkSet
        let keepAliveInterval: UInt
        let connectionTimeout: UInt
        let interOpDelay: UInt
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
    private static let vendorVivo: UInt16 = 0x2D95
    private static let vendorHonor: UInt16 = 0x3511
    private static let vendorRealme: UInt16 = 0x2A96

    // MARK: - Vendor Default Profiles

    private static let vendorProfiles: [UInt16: DeviceProfile] = [
        vendorSamsung: DeviceProfile(
            vendorName: "Samsung",
            quirks: [.samsungPartialObjectBug, .shortIdleTimeout, .customMTPStack,
                     .scopedStorageSlowdown],
            keepAliveInterval: 10,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorXiaomi: DeviceProfile(
            vendorName: "Xiaomi",
            quirks: [.slowEnumeration, .suggestADB, .throttledMTPSpeed,
                     .generalErrorOnDuplicateSession, .scopedStorageSlowdown],
            keepAliveInterval: 12,
            connectionTimeout: 10,
            interOpDelay: 30
        ),
        vendorVivo: DeviceProfile(
            vendorName: "vivo",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorOppo: DeviceProfile(
            vendorName: "OPPO",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorOnePlus: DeviceProfile(
            vendorName: "OnePlus",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorMotorola: DeviceProfile(
            vendorName: "Motorola",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorGoogle: DeviceProfile(
            vendorName: "Google",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorHonor: DeviceProfile(
            vendorName: "Honor",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorRealme: DeviceProfile(
            vendorName: "realme",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 10,
            interOpDelay: 0
        ),
        vendorSony: DeviceProfile(
            vendorName: "Sony",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0,
            connectionTimeout: 0,
            interOpDelay: 0
        ),
        vendorHuawei: DeviceProfile(
            vendorName: "Huawei",
            quirks: [.slowEnumeration, .suggestADB, .scopedStorageSlowdown],
            keepAliveInterval: 12,
            connectionTimeout: 10,
            interOpDelay: 20
        ),
    ]

    // MARK: - Model Overrides

    private struct ModelOverride: Sendable {
        let pattern: String
        let additionalQuirks: QuirkSet
        let keepAliveInterval: UInt?
        let connectionTimeout: UInt?
        let interOpDelay: UInt?
    }

    private static let modelOverrides: [UInt16: [ModelOverride]] = [
        vendorSamsung: [
            ModelOverride(
                pattern: "Galaxy A",
                additionalQuirks: [.slowEnumeration],
                keepAliveInterval: nil,
                connectionTimeout: nil,
                interOpDelay: 10
            ),
        ],
        vendorXiaomi: [
            ModelOverride(
                pattern: "POCO",
                additionalQuirks: [.throttledMTPSpeed],
                keepAliveInterval: nil,
                connectionTimeout: nil,
                interOpDelay: 50
            ),
            ModelOverride(
                pattern: "Redmi Note",
                additionalQuirks: [.slowEnumeration],
                keepAliveInterval: nil,
                connectionTimeout: nil,
                interOpDelay: 40
            ),
        ],
    ]

    private static let defaultProfile = DeviceProfile(
        vendorName: "Unknown",
        quirks: [.scopedStorageSlowdown],
        keepAliveInterval: 0,
        connectionTimeout: 0,
        interOpDelay: 0
    )

    // MARK: - Product String Brand Detection

    private static let productStringBrands: [(pattern: String, profile: DeviceProfile)] = [
        ("tecno", DeviceProfile(
            vendorName: "Tecno",
            quirks: [.scopedStorageSlowdown, .slowEnumeration],
            keepAliveInterval: 0, connectionTimeout: 10, interOpDelay: 15
        )),
        ("infinix", DeviceProfile(
            vendorName: "Infinix",
            quirks: [.scopedStorageSlowdown, .slowEnumeration, .highConnectionLatency],
            keepAliveInterval: 0, connectionTimeout: 15, interOpDelay: 20
        )),
        ("itel", DeviceProfile(
            vendorName: "itel",
            quirks: [.scopedStorageSlowdown, .slowEnumeration],
            keepAliveInterval: 0, connectionTimeout: 10, interOpDelay: 15
        )),
        ("nothing", DeviceProfile(
            vendorName: "Nothing",
            quirks: [.scopedStorageSlowdown],
            keepAliveInterval: 0, connectionTimeout: 0, interOpDelay: 0
        )),
    ]

    private static func detectBrandFromProductString(_ lowercaseName: String) -> DeviceProfile? {
        for (pattern, profile) in productStringBrands {
            if lowercaseName.contains(pattern) {
                return profile
            }
        }
        return nil
    }

    // MARK: - Public API

    static func profile(for vendorID: UInt16, productName: String? = nil) -> DeviceProfile {
        var base = vendorProfiles[vendorID] ?? defaultProfile

        if vendorProfiles[vendorID] == nil, let name = productName {
            if let detected = detectBrandFromProductString(name.lowercased()) {
                base = detected
            }
        }

        guard let name = productName,
              let overrides = modelOverrides[vendorID] else {
            return base
        }

        let lowercaseName = name.lowercased()
        for override in overrides {
            if lowercaseName.contains(override.pattern.lowercased()) {
                return DeviceProfile(
                    vendorName: base.vendorName,
                    quirks: base.quirks.union(override.additionalQuirks),
                    keepAliveInterval: override.keepAliveInterval ?? base.keepAliveInterval,
                    connectionTimeout: override.connectionTimeout ?? base.connectionTimeout,
                    interOpDelay: override.interOpDelay ?? base.interOpDelay
                )
            }
        }

        return base
    }

    static func hasQuirk(_ quirk: QuirkSet, vendorID: UInt16, productName: String? = nil) -> Bool {
        profile(for: vendorID, productName: productName).quirks.contains(quirk)
    }

    static func keepAliveInterval(for vendorID: UInt16, productName: String? = nil) -> UInt {
        let interval = profile(for: vendorID, productName: productName).keepAliveInterval
        return interval > 0 ? interval : 15
    }

    static func connectionTimeout(for vendorID: UInt16, productName: String? = nil) -> UInt {
        let timeout = profile(for: vendorID, productName: productName).connectionTimeout
        return timeout > 0 ? timeout : 5
    }

    static func shouldPreferADB(vendorID: UInt16, productName: String? = nil) -> Bool {
        hasQuirk(.suggestADB, vendorID: vendorID, productName: productName)
    }

    static func shouldAvoidPartialObject(vendorID: UInt16) -> Bool {
        false
    }

    // MARK: - Samsung Boundary Bug

    /// Returns a safe read length if the file triggers Samsung's 512-byte ZLP bug,
    /// or nil if the read is safe.
    static func samsungSafePartialReadLength(
        fileSize: UInt64,
        offset: UInt64,
        requestedLength: UInt64
    ) -> UInt64? {
        let endOffset = offset + requestedLength
        guard endOffset >= fileSize else { return nil }

        let remainder = fileSize % 512
        guard remainder == 500 || remainder == 511 else { return nil }

        return requestedLength > 1 ? requestedLength - 1 : nil
    }
}
