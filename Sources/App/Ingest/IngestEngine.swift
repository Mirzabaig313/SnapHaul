// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import GRDB
import SnapHaulKit
import os

/// Orchestrates the full ingest pipeline:
/// Discovery → Filter → Delta-Sync → Transfer → Verify → Organize → Manifest → Report
actor IngestEngine {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "ingest"
    )

    private let manifestStore: ManifestStore
    private let transferStore: TransferStore
    private let organizer = FileOrganizer()
    private let verifier = ChecksumVerifier()

    init(database: DatabaseQueue) {
        self.manifestStore = ManifestStore(database: database)
        self.transferStore = TransferStore(database: database)
    }

    func runIngest(
        profile: IngestProfile,
        deviceSerial: String,
        engine: any TransferEngine,
        coordinator: TransferCoordinator,
        progressHandler: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> IngestReport {
        let startTime = Date()
        let deviceName = (try? await engine.deviceInfo().displayName) ?? "Unknown Device"
        logger.info("Starting ingest: \(profile.name) for device \(deviceSerial.suffix(4))")

        // 1. Discovery
        var allFiles: [FileItem] = []
        for sourceDir in profile.sourceDirectories {
            do {
                let files = try await engine.listFiles(at: sourceDir)
                allFiles.append(contentsOf: files)
            } catch {
                logger.warning("Could not list \(sourceDir): \(error.localizedDescription)")
            }
        }
        logger.info("Discovered \(allFiles.count) items in source directories")

        // 2. Filter
        let filteredFiles = allFiles.filter { file in
            !file.isDirectory && profile.fileTypeFilters.matches(filename: file.name)
        }
        logger.info("\(filteredFiles.count) files match filters")

        // 3. Delta-sync
        let newFiles: [FileItem]
        do {
            newFiles = try manifestStore.findNewFiles(
                filteredFiles,
                deviceSerial: deviceSerial,
                profileID: profile.id.uuidString
            )
        } catch {
            logger.error("Manifest lookup failed, transferring all filtered files: \(error.localizedDescription)")
            newFiles = filteredFiles
        }

        let skippedCount = filteredFiles.count - newFiles.count
        logger.info("\(newFiles.count) new files to transfer (\(skippedCount) already synced)")

        if newFiles.isEmpty {
            return IngestReport(
                profileName: profile.name,
                deviceName: deviceName,
                deviceSerial: deviceSerial,
                startTime: startTime,
                endTime: Date(),
                totalFiles: 0,
                successfulFiles: 0,
                failedFiles: 0,
                skippedFiles: skippedCount,
                totalBytesTransferred: 0,
                checksumVerified: false
            )
        }

        // 4. Transfer
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapHaul-Staging-\(UUID().uuidString)")

        let summary = try await coordinator.transferFiles(
            newFiles,
            using: engine,
            to: stagingDirectory,
            profileName: profile.name,
            progressHandler: progressHandler
        )

        // 5. Verify checksums
        var checksumPassed = 0
        var checksumFailed = 0
        let isMTPEngine = engine is MTPEngine || engine is MTPNativeEngine
        if profile.checksumVerification && !isMTPEngine {
            for file in newFiles {
                let localURL = stagingDirectory.appendingPathComponent(file.name)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                do {
                    let match = try await verifier.verify(
                        localURL: localURL,
                        remotePath: file.path,
                        engine: engine
                    )
                    if match { checksumPassed += 1 }
                    else { checksumFailed += 1 }
                } catch {
                    logger.warning("Checksum verify error for \(file.name, privacy: .private(mask: .hash)): \(error.localizedDescription)")
                    checksumFailed += 1
                }
            }
            logger.info("Checksum verification: \(checksumPassed) passed, \(checksumFailed) failed")
        } else if profile.checksumVerification && isMTPEngine {
            for file in newFiles {
                let localURL = stagingDirectory.appendingPathComponent(file.name)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                   let localSize = attrs[.size] as? UInt64 {
                    if localSize == file.size {
                        checksumPassed += 1
                    } else {
                        checksumFailed += 1
                        logger.warning("Size mismatch for \(file.name, privacy: .private(mask: .hash)): expected \(file.size), got \(localSize)")
                    }
                }
            }
            logger.info("MTP size verification: \(checksumPassed) passed, \(checksumFailed) failed")
        }

        // 6. Organize
        let finalDestination = URL(fileURLWithPath: profile.destinationPath)
        var organizedFiles: [FileOrganizer.OrganizedFile] = []
        var organizationFailed = false
        do {
            organizedFiles = try organizer.organize(
                files: newFiles,
                transferDirectory: stagingDirectory,
                finalDestination: finalDestination,
                profile: profile
            )
        } catch {
            organizationFailed = true
            logger.error("Organization failed: \(error.localizedDescription). Files remain in staging: \(stagingDirectory.path)")
        }

        let organizedMap = Dictionary(
            uniqueKeysWithValues: organizedFiles.map { ($0.originalItem.path, $0.finalURL) }
        )

        // 7. Batch hash all organized files
        let organizedURLs = newFiles.compactMap { organizedMap[$0.path] }
        let batchHashes = FastXXH3.hashFilesBatch(urls: organizedURLs)
        let hashMap = Dictionary(uniqueKeysWithValues: zip(organizedURLs, batchHashes))

        // 8. Update manifest and transfer history
        let sessionDurationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
        let perFileDurationMs = newFiles.isEmpty ? 0 : sessionDurationMs / Int64(newFiles.count)

        for file in newFiles {
            let hash: String? = organizedMap[file.path]
                .flatMap { hashMap[$0] }
                .flatMap { $0 == "0000000000000000" ? nil : $0 }

            let manifestStatus: String
            if organizationFailed {
                manifestStatus = "transferred_unorganized"
            } else if checksumFailed > 0 {
                manifestStatus = "transferred_unverified"
            } else {
                manifestStatus = "synced"
            }

            do {
                try manifestStore.recordTransfer(
                    filePath: file.path,
                    fileSize: file.size,
                    modificationTime: file.modificationDate,
                    hash: hash,
                    deviceSerial: deviceSerial,
                    profileID: profile.id.uuidString,
                    status: manifestStatus
                )
            } catch {
                logger.error("Failed to record manifest for \(file.name, privacy: .private(mask: .hash)): \(error.localizedDescription)")
            }

            let fileStatus = organizedMap[file.path] != nil ? "success" : "failed"
            do {
                try transferStore.record(
                    deviceSerial: deviceSerial,
                    deviceName: deviceName,
                    profileID: profile.id.uuidString,
                    profileName: profile.name,
                    filePath: file.path,
                    fileSize: file.size,
                    durationMs: perFileDurationMs,
                    checksum: hash,
                    status: fileStatus
                )
            } catch {
                logger.error("Failed to record transfer history for \(file.name, privacy: .private(mask: .hash)): \(error.localizedDescription)")
            }
        }

        // 9. Generate report
        let endTime = Date()
        let totalBytes = newFiles.reduce(UInt64(0)) { $0 + $1.size }

        let report = IngestReport(
            profileName: profile.name,
            deviceName: deviceName,
            deviceSerial: deviceSerial,
            startTime: startTime,
            endTime: endTime,
            totalFiles: newFiles.count,
            successfulFiles: summary.completedFiles - summary.failedFiles,
            failedFiles: summary.failedFiles,
            skippedFiles: skippedCount,
            totalBytesTransferred: totalBytes,
            checksumVerified: profile.checksumVerification,
            checksumPassed: checksumPassed,
            checksumFailed: checksumFailed,
            errors: summary.errors
        )

        logger.info("Ingest complete: \(report.formattedDuration), \(report.totalFiles) files, \(organizedFiles.count) organized")
        return report
    }
}
