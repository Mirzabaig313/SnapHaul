// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import ImageIO
import os

/// Extracts EXIF metadata from image files using Apple's ImageIO framework.
///
/// Supports DNG, ARW, CR3, NEF, HEIC, JPEG, and other formats that
/// `CGImageSource` can read. For video files, returns nil (EXIF is
/// image-specific).
struct EXIFParser {
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "exif")

    /// Cached date formatter for EXIF date strings.
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// EXIF metadata extracted from an image file.
    struct Metadata: Sendable {
        let cameraModel: String?
        let cameraMake: String?
        let dateTaken: Date?
        let lensModel: String?
        let focalLength: Double?
        let isoSpeed: Int?
        let exposureTime: Double?
        let fNumber: Double?
        let imageWidth: Int?
        let imageHeight: Int?
    }

    /// Parse EXIF metadata from a local image file.
    ///
    /// - Parameter url: Local file URL (the transferred file on Mac).
    /// - Returns: Parsed metadata, or nil if the file is not an image
    ///   or has no EXIF data.
    func parse(at url: URL) -> Metadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        // Camera model from TIFF metadata
        let cameraModel = tiff?[kCGImagePropertyTIFFModel as String] as? String
        let cameraMake = tiff?[kCGImagePropertyTIFFMake as String] as? String

        // Date taken from EXIF
        var dateTaken: Date?
        if let dateStr = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            dateTaken = Self.exifDateFormatter.date(from: dateStr)
        }

        // Lens and exposure info
        let lensModel = exif?[kCGImagePropertyExifLensModel as String] as? String
        let focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double
        let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]
        let isoSpeed = isoArray?.first
        let exposureTime = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        let fNumber = exif?[kCGImagePropertyExifFNumber as String] as? Double

        // Image dimensions
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int

        return Metadata(
            cameraModel: cameraModel,
            cameraMake: cameraMake,
            dateTaken: dateTaken,
            lensModel: lensModel,
            focalLength: focalLength,
            isoSpeed: isoSpeed,
            exposureTime: exposureTime,
            fNumber: fNumber,
            imageWidth: width,
            imageHeight: height
        )
    }
}
