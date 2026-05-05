// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Defines which file extensions an ingest profile accepts or rejects.
///
/// An empty `includeExtensions` list means "accept everything" — only
/// `excludeExtensions` is applied. This is the correct default for the
/// File Provider (Finder shows all files) and the "All Files" preset.
public struct FileTypeFilter: Sendable, Codable, Equatable {

    public let includeExtensions: [String]
    public let excludeExtensions: [String]

    public init(include: [String] = [], exclude: [String] = []) {
        self.includeExtensions = include
        self.excludeExtensions = exclude
    }

    /// Accept every file — no filtering.
    public static let allFiles = FileTypeFilter(include: [], exclude: [])

    /// Professional camera media: RAW stills + video.
    /// Delegates to FileTypeRegistry so the definition lives in one place.
    public static var defaultMediaFilter: FileTypeFilter {
        FileTypeRegistry.professionalMedia
    }

    /// Check if a filename passes this filter.
    public func matches(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()

        if !excludeExtensions.isEmpty && excludeExtensions.contains(ext) {
            return false
        }

        // Empty include list = accept everything
        if !includeExtensions.isEmpty {
            return includeExtensions.contains(ext)
        }

        return true
    }
}
