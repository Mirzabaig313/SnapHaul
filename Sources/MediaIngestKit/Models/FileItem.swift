// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import UniformTypeIdentifiers

/// Represents a file or directory on the connected Android device.
///
/// Used across the host app, File Provider extension, and Finder Sync extension
/// via XPC serialization. All properties are value types for `Sendable` conformance.
public struct FileItem: Sendable, Codable, Identifiable, Hashable {

    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date
    public let contentType: String

    public init(
        id: String,
        name: String,
        path: String,
        isDirectory: Bool,
        size: UInt64,
        modificationDate: Date,
        contentType: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.contentType = contentType
    }

    /// Resolved UTType from the content type string.
    public var utType: UTType? {
        UTType(contentType)
    }
}
