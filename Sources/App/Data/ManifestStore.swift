// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
internal import GRDB
import SnapHaulKit
import os

/// GRDB record type for manifest entries.
struct ManifestEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "manifest_entries"

    var id: Int64?
    var deviceSerial: String
    var profileID: String
    var filePath: String
    var fileSize: Int64
    var modificationTime: Date
    var xxh3Hash: String?
    var transferDate: Date
    var status: String  // "synced", "transferred_unverified", "failed"

    // Column mapping for snake_case DB columns → camelCase Swift
    enum Columns: String, ColumnExpression {
        case id, deviceSerial = "device_serial", profileID = "profile_id"
        case filePath = "file_path", fileSize = "file_size"
        case modificationTime = "modification_time", xxh3Hash = "xxh3_hash"
        case transferDate = "transfer_date", status
    }
}

/// Manages delta-sync manifests in SQLite.
///
/// Each manifest entry records a file that has been successfully transferred
/// for a given device + profile combination. On subsequent connections,
/// the manifest is compared against the device's current file list to
/// determine which files are new or modified.
struct ManifestStore {
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "manifest")

    init(database: DatabaseQueue) {
        self.db = database
    }

    /// Find files that need to be transferred (not in manifest or modified).
    ///
    /// Compares the given file list against the stored manifest for this
    /// device + profile. Returns only files that are new or have changed
    /// size/modification time.
    func findNewFiles(
        _ files: [FileItem],
        deviceSerial: String,
        profileID: String
    ) throws -> [FileItem] {
        try db.read { db in
            // Load all manifest entries for this device+profile into a dictionary
            // keyed by file path for O(1) lookup
            let entries = try ManifestEntry
                .filter(ManifestEntry.Columns.deviceSerial == deviceSerial)
                .filter(ManifestEntry.Columns.profileID == profileID)
                .fetchAll(db)

            let manifest = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.filePath, $0) }
            )

            return files.filter { file in
                guard let existing = manifest[file.path] else {
                    return true // New file — not in manifest
                }
                // Check if modified (size or date changed)
                return file.size != UInt64(existing.fileSize) ||
                       abs(file.modificationDate.timeIntervalSince(existing.modificationTime)) > 1.0
            }
        }
    }

    /// Record a successfully transferred file in the manifest.
    func recordTransfer(
        filePath: String,
        fileSize: UInt64,
        modificationTime: Date,
        hash: String?,
        deviceSerial: String,
        profileID: String,
        status: String = "synced"
    ) throws {
        try db.write { db in
            // Upsert via INSERT OR REPLACE on the unique key
            // (device_serial, profile_id, file_path)
            let entry = ManifestEntry(
                deviceSerial: deviceSerial,
                profileID: profileID,
                filePath: filePath,
                fileSize: Int64(fileSize),
                modificationTime: modificationTime,
                xxh3Hash: hash,
                transferDate: Date(),
                status: status
            )
            try entry.insert(db, onConflict: .replace)
        }
    }

    /// Get the count of synced files for a device + profile.
    func syncedFileCount(deviceSerial: String, profileID: String) throws -> Int {
        try db.read { db in
            try ManifestEntry
                .filter(ManifestEntry.Columns.deviceSerial == deviceSerial)
                .filter(ManifestEntry.Columns.profileID == profileID)
                .filter(ManifestEntry.Columns.status == "synced")
                .fetchCount(db)
        }
    }

    /// Clear the manifest for a device + profile (force full re-sync).
    func clearManifest(deviceSerial: String, profileID: String) throws {
        try db.write { db in
            _ = try ManifestEntry
                .filter(ManifestEntry.Columns.deviceSerial == deviceSerial)
                .filter(ManifestEntry.Columns.profileID == profileID)
                .deleteAll(db)
        }
    }
}
