// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Shared byte formatting utility.
///
/// Used across the host app, test tools, and notification manager
/// to format byte counts into human-readable strings.
public enum ByteFormatter {

    /// Format a byte count into a human-readable string.
    ///
    /// Examples: "808.8 KB", "2.1 MB", "148.7 GB"
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
