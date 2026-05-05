// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// Renames and organizes transferred files according to the ingest profile.
///
/// After files are transferred to the destination directory, the organizer:
/// 1. Parses EXIF metadata (for images)
/// 2. Applies the naming template to generate the final filename
/// 3. Creates the subfolder structure
/// 4. Moves the file to its final location
struct FileOrganizer {
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "organizer")
    private let exifParser = EXIFParser()

    /// Result of organizing a single file.
    struct OrganizedFile {
        let originalItem: FileItem
        let finalURL: URL
    }

    /// Organize a batch of transferred files.
    ///
    /// - Parameters:
    ///   - files: The original FileItem list (for metadata like modification date).
    ///   - transferDirectory: Where the files were initially transferred to.
    ///   - finalDestination: The root destination from the ingest profile.
    ///   - profile: The ingest profile with naming template and subfolder structure.
    /// - Returns: Array of organized file results mapping original items to final URLs.
    func organize(
        files: [FileItem],
        transferDirectory: URL,
        finalDestination: URL,
        profile: IngestProfile
    ) throws -> [OrganizedFile] {
        let template = NamingTemplate(template: profile.namingTemplate)
        let subfolderTemplate = profile.subfolderStructure.map { NamingTemplate(template: $0) }
        var results: [OrganizedFile] = []

        for (index, file) in files.enumerated() {
            let sourceURL = transferDirectory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                logger.warning("File not found for organization: \(file.name, privacy: .private(mask: .hash))")
                continue
            }

            // Parse EXIF if it's an image
            let exif = exifParser.parse(at: sourceURL)
            let fileDate = exif?.dateTaken ?? file.modificationDate
            let cameraModel = exif?.cameraModel

            // Generate the new filename
            let newName = template.apply(
                originalName: file.name,
                date: fileDate,
                cameraModel: cameraModel,
                sequenceNumber: index + 1
            )

            // Generate subfolder path
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

            // Create target directory
            try FileManager.default.createDirectory(
                at: targetDir,
                withIntermediateDirectories: true
            )

            // Move file to final location
            let targetURL = targetDir.appendingPathComponent(newName)

            // Handle name collisions by appending a counter
            let finalURL = uniqueURL(for: targetURL)

            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
            results.append(OrganizedFile(originalItem: file, finalURL: finalURL))

            logger.debug("Organized: \(file.name, privacy: .private(mask: .hash)) → \(newName, privacy: .private(mask: .hash))")
        }

        // Clean up the transfer directory if empty
        let remaining = try? FileManager.default.contentsOfDirectory(atPath: transferDirectory.path)
        if remaining?.isEmpty == true {
            try? FileManager.default.removeItem(at: transferDirectory)
        }

        logger.info("Organized \(results.count) files")
        return results
    }

    /// Generate a unique URL by appending a counter if the file already exists.
    ///
    /// Caps at 9999 to prevent infinite loops from permission issues
    /// or other filesystem anomalies.
    private func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for counter in 2...9999 {
            let candidate = directory.appendingPathComponent("\(name)_\(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: use UUID suffix to guarantee uniqueness
        let fallback = directory.appendingPathComponent("\(name)_\(UUID().uuidString.prefix(8)).\(ext)")
        logger.warning("Name collision cap reached for \(name, privacy: .private(mask: .hash)), using UUID suffix")
        return fallback
    }
}
