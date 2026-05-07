// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
internal import GRDB
import SnapHaulKit
import os

/// GRDB record type for a single file's transfer history entry.
struct TransferRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transfer_records"

    var id: Int64?
    var timestamp: Date
    var deviceSerial: String
    var deviceName: String
    var profileID: String?
    var profileName: String?
    var filePath: String
    var fileSize: Int64
    var durationMs: Int64
    var checksum: String?
    var status: String  // "success", "failed", "checksum_mismatch"

    enum Columns: String, ColumnExpression {
        case id, timestamp
        case deviceSerial = "device_serial"
        case deviceName = "device_name"
        case profileID = "profile_id"
        case profileName = "profile_name"
        case filePath = "file_path"
        case fileSize = "file_size"
        case durationMs = "duration_ms"
        case checksum, status
    }
}

/// A summary row shown in the Transfer History tab.
struct TransferSession: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let deviceName: String
    let profileName: String?
    let totalFiles: Int
    let successfulFiles: Int
    let failedFiles: Int
    let totalBytes: UInt64
    let durationMs: Int64

    var formattedDuration: String {
        let secs = Int(durationMs / 1000)
        let mins = secs / 60
        return mins > 0 ? "\(mins)m \(secs % 60)s" : "\(secs)s"
    }

    var formattedSpeed: String {
        guard durationMs > 0 else { return "—" }
        let mbps = Double(totalBytes) / Double(durationMs) / 1000
        return String(format: "%.1f MB/s", mbps)
    }
}

/// Reads and writes transfer history records in SQLite.
struct TransferStore {
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "transfer-store")

    init(database: DatabaseQueue) {
        self.db = database
    }

    // MARK: - Write

    /// Record a single file transfer outcome.
    func record(
        deviceSerial: String,
        deviceName: String,
        profileID: String?,
        profileName: String?,
        filePath: String,
        fileSize: UInt64,
        durationMs: Int64,
        checksum: String?,
        status: String
    ) throws {
        try db.write { db in
            let record = TransferRecord(
                timestamp: Date(),
                deviceSerial: deviceSerial,
                deviceName: deviceName,
                profileID: profileID,
                profileName: profileName,
                filePath: filePath,
                fileSize: Int64(fileSize),
                durationMs: durationMs,
                checksum: checksum,
                status: status
            )
            try record.insert(db)
        }
    }

    // MARK: - Read

    /// Fetch recent transfer sessions grouped by profile + device + day.
    ///
    /// Returns up to `limit` sessions, newest first.
    func fetchRecentSessions(limit: Int = 100) throws -> [TransferSession] {
        try db.read { db in
            // Group records by (device_serial, profile_id, date(timestamp))
            // to reconstruct logical "sessions" from individual file records.
            let sql = """
                SELECT
                    device_name,
                    profile_name,
                    date(timestamp) AS session_date,
                    min(timestamp) AS session_start,
                    count(*) AS total_files,
                    sum(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS successful_files,
                    sum(CASE WHEN status != 'success' THEN 1 ELSE 0 END) AS failed_files,
                    sum(file_size) AS total_bytes,
                    sum(duration_ms) AS total_duration_ms
                FROM transfer_records
                GROUP BY device_serial, profile_id, date(timestamp)
                ORDER BY session_start DESC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
            return rows.map { row in
                TransferSession(
                    id: UUID(),
                    timestamp: row["session_start"] ?? Date(),
                    deviceName: row["device_name"] ?? "Unknown Device",
                    profileName: row["profile_name"],
                    totalFiles: row["total_files"] ?? 0,
                    successfulFiles: row["successful_files"] ?? 0,
                    failedFiles: row["failed_files"] ?? 0,
                    totalBytes: UInt64(row["total_bytes"] as Int64? ?? 0),
                    durationMs: row["total_duration_ms"] ?? 0
                )
            }
        }
    }

    /// Total number of files ever transferred.
    func totalFilesTransferred() throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM transfer_records WHERE status = 'success'"
            ) ?? 0
        }
    }

    /// Delete all transfer history records.
    func clearAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM transfer_records")
        }
    }
}
