// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import FileProvider
import SnapHaulKit
import UniformTypeIdentifiers

/// Wraps a `FileItem` (from the device) as an `NSFileProviderItem` for Finder.
///
/// The item identifier is the full device path (e.g. "/DCIM/Camera/IMG_001.dng").
/// macOS uses this identifier in all subsequent calls (fetchContents, deleteItem, etc.)
/// so it must be stable and unique within the domain.
final class FileProviderItem: NSObject, NSFileProviderItem {

    private let fileID: String
    private let fileName: String
    private let parentID: String
    private let isFolder: Bool
    private let fileSize: Int64
    private let modDate: Date
    private let utType: UTType

    // MARK: - Init from FileItem (primary path)

    /// Create a FileProviderItem from a FileItem returned by the transfer engine.
    ///
    /// - Parameters:
    ///   - file: The FileItem from MTP/ADB enumeration.
    ///   - parentPath: The device path of the containing directory.
    init(from file: FileItem, parentPath: String) {
        self.fileID = file.path
        self.fileName = file.name
        self.parentID = parentPath
        self.isFolder = file.isDirectory
        self.fileSize = Int64(file.size)
        self.modDate = file.modificationDate
        self.utType = UTType(file.contentType) ?? (file.isDirectory ? .folder : .data)
        super.init()
    }

    // MARK: - Init from raw values (used for synthetic items like root)

    init(
        id: String,
        name: String,
        parentID: String,
        isDirectory: Bool,
        size: UInt64,
        modificationDate: Date,
        contentType: UTType
    ) {
        self.fileID = id
        self.fileName = name
        self.parentID = parentID
        self.isFolder = isDirectory
        self.fileSize = Int64(size)
        self.modDate = modificationDate
        self.utType = contentType
        super.init()
    }

    // MARK: - NSFileProviderItem

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(fileID)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        // Root-level items (e.g. /DCIM) have "/" as parent — map to .rootContainer
        if parentID.isEmpty || parentID == "/" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(parentID)
    }

    var filename: String { fileName }

    var contentType: UTType { isFolder ? .folder : utType }

    /// What Finder allows the user to do with this item.
    ///
    /// Read + write + delete for files. Read + enumerate for folders.
    /// Write is enabled so drag-and-drop into the volume works.
    var capabilities: NSFileProviderItemCapabilities {
        if isFolder {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
    }

    var documentSize: NSNumber? {
        isFolder ? nil : NSNumber(value: fileSize)
    }

    var contentModificationDate: Date? { modDate }

    /// Synthesized version from modification time + size.
    ///
    /// MTP has no native versioning. This is sufficient for conflict detection
    /// because a file that changed on the device will have a different mtime or size.
    var itemVersion: NSFileProviderItemVersion {
        let versionString = "\(modDate.timeIntervalSince1970)-\(fileSize)"
        // UTF-8 encoding of ASCII digits and hyphens never fails
        let versionData = versionString.data(using: .utf8)!
        return NSFileProviderItemVersion(
            contentVersion: versionData,
            metadataVersion: versionData
        )
    }
}
