// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Manages Security-Scoped Bookmarks for persistent file access
/// to user-chosen ingest destinations from a sandboxed app.
///
/// The user grants access once via an Open Panel. The app persists
/// the bookmark data in UserDefaults. On subsequent launches, the
/// bookmark is resolved to regain access without prompting again.
public enum SecurityScopedBookmark {

    private static let bookmarkKey = "com.snaphaul.bookmarks"

    /// Create and persist a security-scoped bookmark for the given URL.
    ///
    /// Call this after the user selects a destination via `NSOpenPanel`.
    /// - Parameter url: The URL the user granted access to.
    public static func save(url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var bookmarks = loadAllBookmarks()
        bookmarks[url.path] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    /// Resolve a previously saved bookmark and start accessing the resource.
    ///
    /// - Parameter path: The original path that was bookmarked.
    /// - Returns: The resolved URL with security scope started, or nil if not found.
    public static func resolve(path: String) -> URL? {
        let bookmarks = loadAllBookmarks()
        guard let data = bookmarks[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            // Re-save the bookmark to refresh it
            try? save(url: url)
        }

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        return url
    }

    /// Stop accessing a security-scoped resource.
    public static func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Remove a saved bookmark.
    public static func remove(path: String) {
        var bookmarks = loadAllBookmarks()
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private static func loadAllBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
    }
}
