// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import os.log

/// Pre-flight diagnostics for a local file URL before handing it to a
/// transfer engine. When `open(path, O_RDONLY)` returns EPERM under macOS,
/// the cause can be any of: POSIX mode, extended attributes (quarantine,
/// protected-at-rest), ACLs, symlink target restrictions, TCC scope, or
/// App Sandbox scope. This utility records every observable property so
/// the logs show *which* gate is blocking access.
public enum FilePreflight {

    public struct Report: Sendable, CustomStringConvertible {
        public let path: String
        public let exists: Bool
        public let isSymlink: Bool
        public let resolvedPath: String?
        public let fileSize: UInt64?
        public let posixPermissions: UInt16?
        public let ownerUID: UInt32?
        public let ownerGID: UInt32?
        public let xattrNames: [String]
        public let hasQuarantine: Bool
        public let hasProvenance: Bool
        public let readable: Bool
        public let openErrno: Int32?
        public let openErrnoDescription: String?

        public var description: String {
            var lines: [String] = []
            lines.append("FilePreflight(path: \(path))")
            lines.append("  exists: \(exists)")
            lines.append("  isSymlink: \(isSymlink)")
            if let resolvedPath, resolvedPath != path {
                lines.append("  resolved: \(resolvedPath)")
            }
            if let fileSize {
                lines.append("  size: \(fileSize)")
            }
            if let posixPermissions {
                lines.append("  mode: \(String(format: "0%o", posixPermissions))")
            }
            if let ownerUID, let ownerGID {
                lines.append("  uid/gid: \(ownerUID)/\(ownerGID) (current: \(getuid())/\(getgid()))")
            }
            if !xattrNames.isEmpty {
                lines.append("  xattrs: \(xattrNames.joined(separator: ", "))")
            }
            if hasQuarantine { lines.append("  WARNING: quarantined (Gatekeeper)") }
            if hasProvenance { lines.append("  note: has provenance xattr") }
            lines.append("  readable: \(readable)")
            if let openErrno, let openErrnoDescription {
                lines.append("  open() failed: errno=\(openErrno) (\(openErrnoDescription))")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Run every non-mutating probe we can against `url` and collect results.
    /// Does not actually transfer the file. Safe to call from any actor.
    public static func inspect(url: URL) -> Report {
        let path = url.path
        var exists = false
        var isSymlink = false
        var resolvedPath: String? = nil
        var fileSize: UInt64? = nil
        var posixPermissions: UInt16? = nil
        var ownerUID: UInt32? = nil
        var ownerGID: UInt32? = nil
        var xattrNames: [String] = []
        var readable = false
        var openErrno: Int32? = nil
        var openErrnoDescription: String? = nil

        var ls = stat()
        if lstat(path, &ls) == 0 {
            exists = true
            isSymlink = (ls.st_mode & S_IFMT) == S_IFLNK

            if isSymlink {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                let len = readlink(path, &buf, buf.count - 1)
                if len > 0 {
                    buf[len] = 0
                    resolvedPath = String(cString: buf)
                }
            }

            var s = stat()
            if stat(path, &s) == 0 {
                fileSize = UInt64(s.st_size)
                posixPermissions = UInt16(s.st_mode & 0o7777)
                ownerUID = s.st_uid
                ownerGID = s.st_gid
            }
        }

        let listSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if listSize > 0 {
            var names = [CChar](repeating: 0, count: listSize)
            if listxattr(path, &names, listSize, XATTR_NOFOLLOW) == listSize {
                var start = 0
                for i in 0..<listSize {
                    if names[i] == 0 {
                        let slice = Array(names[start..<i])
                        if !slice.isEmpty {
                            xattrNames.append(String(cString: slice + [0]))
                        }
                        start = i + 1
                    }
                }
            }
        }
        let hasQuarantine = xattrNames.contains("com.apple.quarantine")
        let hasProvenance = xattrNames.contains("com.apple.provenance")

        readable = access(path, R_OK) == 0

        if !readable {
            let fd = open(path, O_RDONLY)
            if fd < 0 {
                openErrno = errno
                openErrnoDescription = String(cString: strerror(errno))
            } else {
                close(fd)
                readable = true
            }
        }

        return Report(
            path: path,
            exists: exists,
            isSymlink: isSymlink,
            resolvedPath: resolvedPath,
            fileSize: fileSize,
            posixPermissions: posixPermissions,
            ownerUID: ownerUID,
            ownerGID: ownerGID,
            xattrNames: xattrNames,
            hasQuarantine: hasQuarantine,
            hasProvenance: hasProvenance,
            readable: readable,
            openErrno: openErrno,
            openErrnoDescription: openErrnoDescription
        )
    }

    /// Log the full preflight report. Intended to be called right before
    /// the engine opens the file, so the log sits next to any EPERM error.
    public static func log(_ report: Report, logger: Logger) {
        logger.info("""
        File preflight — path: \(report.path, privacy: .public)
        exists: \(report.exists, privacy: .public) symlink: \(report.isSymlink, privacy: .public)\
        \(report.resolvedPath.map { " → \($0)" } ?? "")
        size: \(report.fileSize ?? 0, privacy: .public)
        mode: \(report.posixPermissions.map { String(format: "0%o", $0) } ?? "?", privacy: .public)
        uid/gid: \(report.ownerUID ?? 0, privacy: .public)/\(report.ownerGID ?? 0, privacy: .public) (me: \(getuid())/\(getgid()))
        xattrs: \(report.xattrNames.joined(separator: ","), privacy: .public)
        readable: \(report.readable, privacy: .public)\
        \(report.openErrno.map { " errno=\($0) (\(report.openErrnoDescription ?? "?"))" } ?? "")
        """)
    }
}
