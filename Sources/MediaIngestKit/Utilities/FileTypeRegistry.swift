// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import UniformTypeIdentifiers

/// Single source of truth for file type knowledge across the app.
///
/// Used by ADBEngine, MTPEngine, FileProviderItem, and IngestProfile
/// so all four agree on what a given extension means.
///
/// Design: empty include list = accept everything. This is the default
/// for the File Provider (Finder shows all files) and the "All Files"
/// ingest preset. Specific presets narrow it down via includeExtensions.
public enum FileTypeRegistry {

    // MARK: - UTType strings

    /// Map a filename to a UTType identifier string.
    ///
    /// Returns `"public.data"` for unknown extensions — this is the correct
    /// fallback that lets Finder display the file with a generic icon rather
    /// than refusing to show it.
    public static func utTypeString(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return utTypeByExtension[ext] ?? "public.data"
    }

    /// Map a filename to a UTType value.
    public static func utType(for filename: String) -> UTType {
        let str = utTypeString(for: filename)
        return UTType(str) ?? .data
    }

    // MARK: - Preset filters

    /// Accept every file — no filtering. Used by File Provider and
    /// the "All Files" ingest preset.
    public static let allFiles = FileTypeFilter(include: [], exclude: [])

    /// Professional camera media: RAW stills + video. Excludes JPEG/PNG
    /// thumbnails that cameras write alongside RAW files.
    public static let professionalMedia = FileTypeFilter(
        include: [
            // RAW stills
            "dng", "arw", "cr3", "cr2", "nef", "nrw", "raf", "rw2",
            "orf", "pef", "srw", "x3f", "3fr", "mef", "rwl", "iiq",
            // Video
            "mp4", "mov", "m4v", "mts", "m2ts", "avi", "mkv",
            "r3d", "braw", "ari",
            // HEIF/HEIC (iPhone, modern Android)
            "heic", "heif",
        ],
        exclude: [
            // Camera-generated thumbnails and previews
            "thm", "xmp",
        ]
    )

    /// All image formats — RAW, JPEG, PNG, HEIC, WebP, everything.
    public static let allImages = FileTypeFilter(
        include: [
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp",
            "heic", "heif", "avif",
            "dng", "arw", "cr3", "cr2", "nef", "nrw", "raf", "rw2",
            "orf", "pef", "srw", "x3f", "3fr", "mef", "rwl", "iiq",
        ],
        exclude: []
    )

    /// All video formats.
    public static let allVideo = FileTypeFilter(
        include: [
            "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
            "mts", "m2ts", "ts", "3gp", "3g2",
            "r3d", "braw", "ari",
        ],
        exclude: []
    )

    /// All audio formats.
    public static let allAudio = FileTypeFilter(
        include: [
            "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif",
            "ogg", "opus", "wma", "alac",
        ],
        exclude: []
    )

    /// Documents: PDF, Office, text.
    public static let documents = FileTypeFilter(
        include: [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "txt", "rtf", "md", "csv",
            "pages", "numbers", "key",
            "odt", "ods", "odp",
        ],
        exclude: []
    )

    // MARK: - Extension → UTType map

    /// Complete extension → UTType identifier mapping.
    ///
    /// Covers every format commonly found on Android devices.
    /// Unknown extensions fall back to "public.data" at the call site.
    public static let utTypeByExtension: [String: String] = [

        // ── Images ────────────────────────────────────────────────────────────
        "jpg":   "public.jpeg",
        "jpeg":  "public.jpeg",
        "png":   "public.png",
        "gif":   "com.compuserve.gif",
        "bmp":   "com.microsoft.bmp",
        "tiff":  "public.tiff",
        "tif":   "public.tiff",
        "webp":  "org.webmproject.webp",
        "heic":  "public.heic",
        "heif":  "public.heif",
        "avif":  "public.avif",
        "ico":   "com.microsoft.ico",
        "svg":   "public.svg-image",

        // ── RAW camera formats ────────────────────────────────────────────────
        "dng":   "com.adobe.raw-image",
        "arw":   "com.sony.arw-raw-image",
        "cr3":   "com.canon.cr3-raw-image",
        "cr2":   "com.canon.raw-image",
        "nef":   "com.nikon.nef-raw-image",
        "nrw":   "com.nikon.nrw-raw-image",
        "raf":   "com.fuji.raw-image",
        "rw2":   "com.panasonic.raw-image",
        "orf":   "com.olympus.raw-image",
        "pef":   "com.pentax.raw-image",
        "srw":   "com.samsung.raw-image",
        "x3f":   "com.sigma.x3f-raw-image",
        "3fr":   "com.hasselblad.3fr-raw-image",
        "mef":   "com.mamiya.raw-image",
        "rwl":   "com.leica.raw-image",
        "iiq":   "com.phaseone.raw-image",

        // ── Video ─────────────────────────────────────────────────────────────
        "mp4":   "public.mpeg-4",
        "m4v":   "com.apple.m4v-video",
        "mov":   "com.apple.quicktime-movie",
        "avi":   "public.avi",
        "mkv":   "org.matroska.mkv",
        "wmv":   "com.microsoft.windows-media-wmv",
        "flv":   "com.adobe.flash.video",
        "webm":  "org.webmproject.webm",
        "mts":   "public.mpeg-2-transport-stream",
        "m2ts":  "public.mpeg-2-transport-stream",
        "ts":    "public.mpeg-2-transport-stream",
        "3gp":   "public.3gpp",
        "3g2":   "public.3gpp2",
        "r3d":   "com.red.r3d",
        "braw":  "com.blackmagicdesign.braw",
        "ari":   "com.arri.ari",
        "mxf":   "org.smpte.mxf",

        // ── Audio ─────────────────────────────────────────────────────────────
        "mp3":   "public.mp3",
        "m4a":   "public.mpeg-4-audio",
        "aac":   "public.aac-audio",
        "flac":  "org.xiph.flac",
        "wav":   "com.microsoft.waveform-audio",
        "aiff":  "public.aiff-audio",
        "aif":   "public.aiff-audio",
        "ogg":   "org.xiph.ogg-vorbis",
        "opus":  "org.xiph.opus",
        "wma":   "com.microsoft.windows-media-wma",
        "alac":  "com.apple.m4a-audio",
        "mid":   "public.midi-audio",
        "midi":  "public.midi-audio",
        "amr":   "org.3gpp.adaptive-multi-rate-audio",

        // ── Documents ─────────────────────────────────────────────────────────
        "pdf":   "com.adobe.pdf",
        "doc":   "com.microsoft.word.doc",
        "docx":  "org.openxmlformats.wordprocessingml.document",
        "xls":   "com.microsoft.excel.xls",
        "xlsx":  "org.openxmlformats.spreadsheetml.sheet",
        "ppt":   "com.microsoft.powerpoint.ppt",
        "pptx":  "org.openxmlformats.presentationml.presentation",
        "pages": "com.apple.iwork.pages.pages",
        "numbers": "com.apple.iwork.numbers.numbers",
        "key":   "com.apple.iwork.keynote.key",
        "odt":   "org.oasis-open.opendocument.text",
        "ods":   "org.oasis-open.opendocument.spreadsheet",
        "odp":   "org.oasis-open.opendocument.presentation",
        "epub":  "org.idpf.epub-container",

        // ── Text & code ───────────────────────────────────────────────────────
        "txt":   "public.plain-text",
        "rtf":   "public.rtf",
        "md":    "net.daringfireball.markdown",
        "csv":   "public.comma-separated-values-text",
        "json":  "public.json",
        "xml":   "public.xml",
        "html":  "public.html",
        "htm":   "public.html",
        "css":   "public.css",
        "js":    "com.netscape.javascript-source",
        // "ts" is already mapped above as mpeg-2-transport-stream (video takes precedence on Android)
        "swift": "public.swift-source",
        "py":    "public.python-script",
        "sh":    "public.shell-script",
        "log":   "public.plain-text",

        // ── Archives ──────────────────────────────────────────────────────────
        "zip":   "public.zip-archive",
        "rar":   "com.rarlab.rar-archive",
        "7z":    "org.7-zip.7-zip-archive",
        "tar":   "public.tar-archive",
        "gz":    "org.gnu.gnu-zip-archive",
        "tgz":   "org.gnu.gnu-zip-tar-archive",
        "bz2":   "public.bzip2-archive",
        "xz":    "org.tukaani.xz-archive",

        // ── Android-specific ──────────────────────────────────────────────────
        "apk":   "com.android.package-archive",
        "aab":   "com.android.app-bundle",
        "obb":   "com.android.obb",

        // ── Fonts ─────────────────────────────────────────────────────────────
        "ttf":   "public.truetype-ttf-font",
        "otf":   "public.opentype-font",
        "woff":  "org.w3.woff",
        "woff2": "org.w3.woff2",

        // ── 3D / design ───────────────────────────────────────────────────────
        "obj":   "public.geometry-definition-format",
        "fbx":   "com.autodesk.fbx",
        "gltf":  "model/gltf+json",
        "glb":   "model/gltf-binary",
        "stl":   "public.standard-tesselated-geometry-format",
        "psd":   "com.adobe.photoshop-image",
        "ai":    "com.adobe.illustrator.ai-image",
        "sketch": "com.bohemiancoding.sketch.drawing",
        "fig":   "com.figma.document",

        // ── Misc ──────────────────────────────────────────────────────────────
        "ics":   "com.apple.ical.ics",
        "vcf":   "public.vcard",
        "gpx":   "com.topografix.gpx",
        "kml":   "com.google.earth.kml",
        "torrent": "org.bittorrent.torrent",
        "db":    "public.database",
        "sqlite": "public.database",
    ]
}
