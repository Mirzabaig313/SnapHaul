// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Utilities for filename validation, sanitization, and filtering.
public enum FileNameUtils {

    // MARK: - System File Filter

    /// Files that should never be transferred between Mac and Android.
    private static let blockedNames: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        "Thumbs.db",
        "desktop.ini",
        "ehthumbs.db",
    ]

    /// Returns true if the file should be skipped during transfer.
    public static func shouldSkip(_ filename: String) -> Bool {
        if blockedNames.contains(filename) { return true }
        if filename.hasPrefix("._") { return true }  // macOS resource forks
        return false
    }

    // MARK: - MTP Filename Sanitization

    /// Characters illegal on FAT32/exFAT (Android's underlying filesystem).
    private static let mtpDisallowedCharacters = CharacterSet(charactersIn: ":*?\"<>|[]")

    /// Sanitize a filename for MTP push — replaces illegal characters with underscore.
    /// Also truncates to 120 characters (some Android MTP stacks reject longer names).
    public static func sanitizeForMTP(_ filename: String) -> String {
        var result = ""
        result.reserveCapacity(filename.count)
        for scalar in filename.unicodeScalars {
            if mtpDisallowedCharacters.contains(scalar) {
                result.append("_")
            } else {
                result.append(Character(scalar))
            }
        }
        if result.count > 120 {
            let ext = (result as NSString).pathExtension
            let stem = (result as NSString).deletingPathExtension
            let maxStem = 120 - ext.count - 1
            result = String(stem.prefix(maxStem)) + "." + ext
        }
        return result
    }
}
