// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// Renames and organizes transferred files according to the ingest profile.
struct FileOrganizer {
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "organizer")
    private let exifParser = EXIFParser()
    private let bufferPool = TransferBufferPool(bufferSize: 4 * 1024 * 1024, count: 2)

    struct OrganizedFile {
        let originalItem: FileItem
        let finalURL: URL
    }

    func organize(
        files: [FileItem],
        transferDirectory: URL,
        finalDestination: URL,
        profile: IngestProfile
    ) throws -> [OrganizedFile] {
        let template = NamingTemplate(template: profile.namingTemplate)
        let subfolderTemplate = profile.subfolderStructure.map { NamingTemplate(template: $0) }
        var results: [OrganizedFile] = []

        // Batch EXIF date extraction via C for all eligible files
        let needsCamera = profile.namingTemplate.contains("{camera}")
        let exifURLs: [URL] = files.compactMap { file in
            guard FastEXIF.supportsEXIF(file.name) else { return nil }
            let url = transferDirectory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        let batchDates = FastEXIF.extractDatesBatch(urls: exifURLs)
        let exifDateMap = Dictionary(
            uniqueKeysWithValues: zip(exifURLs.map { $0.lastPathComponent }, batchDates)
        )

        for (index, file) in files.enumerated() {
            let sourceURL = transferDirectory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                logger.warning("File not found for organization: \(file.name, privacy: .private(mask: .hash))")
                continue
            }

            let fileDate: Date
            let cameraModel: String?
            if let batchDate = exifDateMap[file.name] ?? nil {
                fileDate = batchDate.date ?? file.modificationDate
                if needsCamera {
                    cameraModel = exifParser.parse(at: sourceURL)?.cameraModel
                } else {
                    cameraModel = nil
                }
            } else if FastEXIF.supportsEXIF(file.name),
                      let fastDate = FastEXIF.extractDate(from: sourceURL) {
                fileDate = fastDate.date ?? file.modificationDate
                cameraModel = needsCamera ? exifParser.parse(at: sourceURL)?.cameraModel : nil
            } else {
                let exif = exifParser.parse(at: sourceURL)
                fileDate = exif?.dateTaken ?? file.modificationDate
                cameraModel = exif?.cameraModel
            }

            let newName = template.apply(
                originalName: file.name,
                date: fileDate,
                cameraModel: cameraModel,
                sequenceNumber: index + 1
            )

            var targetDir = finalDestination
            if let subTemplate = subfolderTemplate {
                let subPath = subTemplate.apply(
                    originalName: file.name,
                    date: fileDate,
                    cameraModel: cameraModel,
                    sequenceNumber: index + 1
                )
                targetDir = finalDestination.appendingPathComponent(subPath)
            }

            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let targetURL = targetDir.appendingPathComponent(newName)
            let finalURL = uniqueURL(for: targetURL)

            // Cross-volume moves fail — fall back to pooled copy (no per-file allocation)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: finalURL)
            } catch CocoaError.fileWriteOutOfSpace {
                throw CocoaError(.fileWriteOutOfSpace)
            } catch {
                if let pool = bufferPool {
                    _ = try pool.copyFile(from: sourceURL, to: finalURL)
                } else {
                    _ = try FastCopy.copy(from: sourceURL, to: finalURL)
                }
                try FileManager.default.removeItem(at: sourceURL)
            }
            results.append(OrganizedFile(originalItem: file, finalURL: finalURL))

            logger.debug("Organized: \(file.name, privacy: .private(mask: .hash)) → \(newName, privacy: .private(mask: .hash))")
        }

        let remaining = try? FileManager.default.contentsOfDirectory(atPath: transferDirectory.path)
        if remaining?.isEmpty == true {
            try? FileManager.default.removeItem(at: transferDirectory)
        }

        logger.info("Organized \(results.count) files")
        return results
    }

    private func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for counter in 2...9999 {
            let candidate = directory.appendingPathComponent("\(name)_\(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let fallback = directory.appendingPathComponent("\(name)_\(UUID().uuidString.prefix(8)).\(ext)")
        logger.warning("Name collision cap reached for \(name, privacy: .private(mask: .hash)), using UUID suffix")
        return fallback
    }
}
