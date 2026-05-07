// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
internal import GRDB
import os

/// Central database manager for SQLite storage.
///
/// Manages two tables:
/// - `manifest_entries` — delta-sync file manifests per device/profile
/// - `transfer_records` — historical log of all transfers
///
/// Uses WAL mode and mmap for performance. See RPD §7.5.2.
struct AppDatabase {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "database"
    )

    let dbQueue: DatabaseQueue

    /// Initialize the database at the standard application support location.
    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SnapHaul", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        let dbPath = appSupport.appendingPathComponent("mediaingest.sqlite").path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try migrate()

        logger.info("Database initialized at \(dbPath, privacy: .private(mask: .hash))")
    }

    /// Run database migrations.
    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "manifest_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("device_serial", .text).notNull()
                t.column("profile_id", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("file_size", .integer).notNull()
                t.column("modification_time", .datetime).notNull()
                t.column("xxh3_hash", .text)
                t.column("transfer_date", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "synced")

                t.uniqueKey(["device_serial", "profile_id", "file_path"])
            }

            try db.create(table: "transfer_records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("device_serial", .text).notNull()
                t.column("device_name", .text).notNull()
                t.column("profile_id", .text)
                t.column("profile_name", .text)
                t.column("file_path", .text).notNull()
                t.column("file_size", .integer).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("checksum", .text)
                t.column("status", .text).notNull()
            }

            // Indexes for common queries
            try db.create(
                index: "idx_manifest_device_profile",
                on: "manifest_entries",
                columns: ["device_serial", "profile_id"]
            )
            try db.create(
                index: "idx_transfer_timestamp",
                on: "transfer_records",
                columns: ["timestamp"]
            )
        }

        try migrator.migrate(dbQueue)
    }
}
