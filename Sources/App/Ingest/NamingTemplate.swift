// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation

/// Parses and applies file naming templates for ingest organization.
///
/// Supported tokens:
/// - `{date}` — YYYYMMDD from EXIF or file modification date
/// - `{time}` — HHmmss
/// - `{year}`, `{month}`, `{day}` — individual date components
/// - `{camera}` — camera model from EXIF (sanitized for filesystem)
/// - `{sequence}` — zero-padded sequence number (0001, 0002, ...)
/// - `{original}` — original filename without extension
/// - `{ext}` — file extension (lowercase)
struct NamingTemplate {

    let template: String

    /// Apply the template to generate a filename.
    ///
    /// - Parameters:
    ///   - originalName: Original filename from the device.
    ///   - date: File date (from EXIF or modification time).
    ///   - cameraModel: Camera model string from EXIF.
    ///   - sequenceNumber: Position in the transfer queue.
    /// - Returns: The generated filename.
    func apply(
        originalName: String,
        date: Date,
        cameraModel: String?,
        sequenceNumber: Int
    ) -> String {
        let ext = (originalName as NSString).pathExtension.lowercased()
        let nameWithoutExt = (originalName as NSString).deletingPathExtension

        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        let sanitizedCamera = (cameraModel ?? "Unknown")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "-")

        var result = template
        result = result.replacingOccurrences(
            of: "{date}",
            with: String(format: "%04d%02d%02d",
                         components.year ?? 0,
                         components.month ?? 0,
                         components.day ?? 0)
        )
        result = result.replacingOccurrences(
            of: "{time}",
            with: String(format: "%02d%02d%02d",
                         components.hour ?? 0,
                         components.minute ?? 0,
                         components.second ?? 0)
        )
        result = result.replacingOccurrences(
            of: "{year}",
            with: String(format: "%04d", components.year ?? 0)
        )
        result = result.replacingOccurrences(
            of: "{month}",
            with: String(format: "%02d", components.month ?? 0)
        )
        result = result.replacingOccurrences(
            of: "{day}",
            with: String(format: "%02d", components.day ?? 0)
        )
        result = result.replacingOccurrences(of: "{camera}", with: sanitizedCamera)
        result = result.replacingOccurrences(
            of: "{sequence}",
            // Zero-pad to 4 digits; for sequences > 9999 use the full number
            // to avoid truncation and filename collisions.
            with: sequenceNumber <= 9999
                ? String(format: "%04d", sequenceNumber)
                : String(sequenceNumber)
        )
        result = result.replacingOccurrences(of: "{original}", with: nameWithoutExt)
        result = result.replacingOccurrences(of: "{ext}", with: ext)

        return result
    }
}
