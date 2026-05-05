// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// OEM-specific workarounds for known MTP implementation bugs.
///
/// Different Android manufacturers implement MTP differently.
/// This registry maps vendor/product IDs to known quirks and
/// the workarounds needed.
///
/// Add new entries as devices are tested. Document the device name,
/// firmware version, and the specific bug in a code comment.
enum DeviceQuirks {

    struct Quirk: Sendable {
        let vendorID: UInt16
        let productID: UInt16?  // nil = applies to all products from this vendor
        let description: String
        let workaround: Workaround
    }

    enum Workaround {
        /// Use chunked reads for files > 4 GB (Samsung MTP reports wrong size)
        case chunkedLargeFiles
        /// Add extra delay between MTP operations (Xiaomi drops connection)
        case interOperationDelay(milliseconds: Int)
        /// Re-open session after idle timeout (OnePlus closes session after 60s)
        case aggressiveKeepAlive(intervalSeconds: Int)
        /// Skip GetPartialObject (some devices don't support it)
        case noPartialObject
    }

    /// Known device quirks registry.
    ///
    /// Samsung Galaxy S24/S25: Reports incorrect file size for files > 4 GB via MTP.
    /// Workaround: Use chunked reads with GetPartialObject.
    static let knownQuirks: [Quirk] = [
        Quirk(
            vendorID: 0x04E8,  // Samsung
            productID: nil,
            description: "Samsung MTP reports incorrect size for files > 4 GB",
            workaround: .chunkedLargeFiles
        ),
        Quirk(
            vendorID: 0x2717,  // Xiaomi
            productID: nil,
            description: "Xiaomi MTP drops connection during rapid sequential operations",
            workaround: .interOperationDelay(milliseconds: 50)
        ),
        Quirk(
            vendorID: 0x2A70,  // OnePlus
            productID: nil,
            description: "OnePlus closes MTP session after 60s idle",
            workaround: .aggressiveKeepAlive(intervalSeconds: 30)
        )
    ]

    /// Look up quirks for a given device.
    static func quirks(vendorID: UInt16, productID: UInt16) -> [Quirk] {
        knownQuirks.filter { quirk in
            quirk.vendorID == vendorID &&
            (quirk.productID == nil || quirk.productID == productID)
        }
    }
}
