// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import os

/// ADB transfer engine.
///
/// Manages the bundled or user-installed `adb` binary as a child process.
/// Uses `adb pull`/`adb push` for file transfers and `adb shell` for
/// metadata queries and remote checksums.
///
/// All process spawning is async via `withCheckedThrowingContinuation`
/// to avoid blocking the actor.
actor ADBEngine: TransferEngine {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "adb"
    )

    private var connected = false
    private var deviceSerial: String?

    /// Resolved path to the adb binary.
    private let adbPath: String

    init() {
        // Search order: Homebrew ARM → Homebrew Intel → bundled → PATH
        let searchPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]

        if let found = searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            self.adbPath = found
        } else if let bundled = Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "adb") {
            self.adbPath = bundled
        } else {
            self.adbPath = "adb"
        }
    }

    var isConnected: Bool { connected }

    // MARK: - Connection

    func connect(device: USBDevice) async throws {
        logger.info("Connecting via ADB to \(device.displayName)")

        // Check if adb binary exists
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            throw ADBError.binaryNotFound
        }

        // Start server if needed, then list devices
        _ = try? await runADB(["start-server"])
        let devicesOutput = try await runADB(["devices", "-l"])

        // Parse `adb devices -l` output to find our device
        // Format: "SERIAL    device usb:... product:... model:... device:..."
        let lines = devicesOutput.components(separatedBy: "\n")
        var foundSerial: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("List of"),
                  !trimmed.hasPrefix("*") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count >= 2 else { continue }

            let serial = String(parts[0])
            let status = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Check for authorization issues
            if status.hasPrefix("unauthorized") {
                if serial == device.serialNumber || foundSerial == nil {
                    throw ADBError.deviceNotAuthorized(device: device.displayName)
                }
                continue
            }

            // Match by serial if possible, otherwise take the first online device
            if serial == device.serialNumber {
                foundSerial = serial
                break
            } else if status.hasPrefix("device") && foundSerial == nil {
                foundSerial = serial
            }
        }

        guard let serial = foundSerial else {
            throw ADBError.deviceOffline(device: device.displayName)
        }

        deviceSerial = serial
        connected = true
        logger.info("ADB connection established with \(device.displayName) [serial: \(serial.suffix(4))]")
    }

    func disconnect() async {
        logger.info("Disconnecting ADB session")
        deviceSerial = nil
        connected = false
    }

    // MARK: - File Operations

    func listFiles(at path: String) async throws -> [FileItem] {
        let serial = try requireSerial()
        logger.debug("ADB listFiles at: \(path, privacy: .private(mask: .hash))")

        // Use `ls -la` for detailed listing, `stat` for accurate sizes
        let output = try await runADB([
            "-s", serial, "shell",
            "ls", "-la", path
        ])

        return parseLsOutput(output, parentPath: path)
    }

    func readFile(at path: String, offset: UInt64, length: UInt64) async throws -> Data {
        let serial = try requireSerial()

        // Pull to temp file, read into memory
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-adb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await runADB(["-s", serial, "pull", path, tempURL.path])
        let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)

        // Apply offset/length
        if offset == 0 && (length == UInt64.max || length >= UInt64(data.count)) {
            return data
        }
        let start = min(Int(offset), data.count)
        let end = min(start + Int(length), data.count)
        return data.subdata(in: start..<end)
    }

    func pullFile(
        from remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UInt64 {
        let serial = try requireSerial()
        logger.debug("ADB pullFile: \(remotePath, privacy: .private(mask: .hash)) → local")

        // Ensure parent directory exists
        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // `adb pull` writes directly to the destination — no memory buffering
        let output = try await runADB(["-s", serial, "pull", remotePath, localURL.path])

        // Parse the transfer speed from adb output
        // Format: "/path/to/file: 1 file pulled, 0 skipped. 25.3 MB/s (808832 bytes in 0.030s)"
        let fileSize = parseADBPullSize(output) ?? 0

        // Fallback: read file size from disk
        let actualSize: UInt64
        if fileSize > 0 {
            actualSize = fileSize
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                  let size = attrs[.size] as? UInt64 {
            actualSize = size
        } else {
            actualSize = 0
        }

        progress?(actualSize)

        logger.debug("Pulled \(actualSize) bytes via ADB: \(remotePath, privacy: .private(mask: .hash))")
        return actualSize
    }

    func writeFile(at path: String, data: Data) async throws {
        let serial = try requireSerial()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-adb-push-\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try await runADB(["-s", serial, "push", tempURL.path, path])
    }

    func deleteFile(at path: String) async throws {
        let serial = try requireSerial()
        _ = try await runADB(["-s", serial, "shell", "rm", "-f", path])
    }

    /// Rename a file on the Android device via ADB.
    ///
    /// Uses `adb shell mv` to rename in-place (same directory).
    /// The file stays in the same directory — only the filename changes.
    func renameFile(at path: String, to newName: String) async throws {
        let serial = try requireSerial()
        logger.info("ADB renameFile: \(path, privacy: .private(mask: .hash)) → \(newName, privacy: .private(mask: .hash))")

        // Build the destination path: same directory, new filename
        let directory = (path as NSString).deletingLastPathComponent
        let newPath = (directory as NSString).appendingPathComponent(newName)

        // Use mv — works for both files and directories
        _ = try await runADB(["-s", serial, "shell", "mv", path, newPath])

        logger.info("ADB renameFile complete: \(newPath, privacy: .private(mask: .hash))")
    }

    // MARK: - Device Info

    func deviceInfo() async throws -> DeviceState {
        let serial = try requireSerial()

        let model = (try? await shellGetProp(serial: serial, prop: "ro.product.model")) ?? "ADB Device"
        let manufacturer = (try? await shellGetProp(serial: serial, prop: "ro.product.manufacturer")) ?? "Unknown"

        // Get storage info via `df`
        var storageTotal: UInt64?
        var storageFree: UInt64?
        if let dfOutput = try? await runADB(["-s", serial, "shell", "df", "/storage/emulated/0"]) {
            let parsed = parseDfOutput(dfOutput)
            storageTotal = parsed.total
            storageFree = parsed.free
        }

        return DeviceState(
            serialNumber: serial,
            displayName: model,
            manufacturer: manufacturer,
            model: model,
            connectionStatus: .connected,
            engineType: .adb,
            storageTotal: storageTotal,
            storageFree: storageFree
        )
    }

    func remoteChecksum(at path: String, algorithm: ChecksumAlgorithm) async throws -> String? {
        let serial = try requireSerial()
        switch algorithm {
        case .sha256:
            let output = try await runADB(["-s", serial, "shell", "sha256sum", path])
            return output.split(separator: " ").first.map(String.init)
        case .xxh3:
            guard let output = try? await runADB(["-s", serial, "shell", "xxhsum", path]) else {
                return nil
            }
            return output.split(separator: " ").first.map(String.init)
        }
    }

    // MARK: - Helpers

    private func requireSerial() throws -> String {
        guard let serial = deviceSerial else {
            throw ADBError.deviceOffline(device: "unknown")
        }
        return serial
    }

    deinit {
        if connected {
            // Can't call async disconnect() from deinit, but log the warning.
            // The ADB server continues running independently — no resource leak,
            // but the caller should have called disconnect() for clean logging.
            let serial = deviceSerial ?? "unknown"
            let redacted = serial.count > 4 ? "***\(serial.suffix(4))" : "****"
            print("[SnapHaul] Warning: ADBEngine deallocated while still connected [\(redacted)]")
        }
    }

    private func shellGetProp(serial: String, prop: String) async throws -> String {
        let output = try await runADB(["-s", serial, "shell", "getprop", prop])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output Parsing

    /// Cached date formatter for `ls -la` output parsing.
    /// `DateFormatter` is expensive to create — reuse across all calls.
    private static let lsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parse `ls -la` output into FileItem array.
    ///
    /// Format varies by Android version but typically:
    /// ```
    /// drwxrwx--x  5 root sdcard_rw  4096 2026-01-15 10:30 DCIM
    /// -rw-rw----  1 root sdcard_rw 808832 2025-06-18 12:06 IMG_001.jpg
    /// ```
    private func parseLsOutput(_ output: String, parentPath: String) -> [FileItem] {
        var items: [FileItem] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("total"),
                  !trimmed.hasPrefix("ls:") else { continue }

            // Split by whitespace, expecting at least 8 fields
            let parts = trimmed.split(
                separator: " ",
                maxSplits: 7,
                omittingEmptySubsequences: true
            ).map(String.init)

            guard parts.count >= 8 else { continue }

            let permissions = parts[0]
            let isDirectory = permissions.hasPrefix("d")
            let isSymlink = permissions.hasPrefix("l")

            // Name is the last field (may contain spaces — take everything after the 7th field)
            var name: String
            if parts.count > 8 {
                name = parts[7...].joined(separator: " ")
            } else {
                name = parts[7]
            }

            // Strip symlink target: "name -> /target/path" → "name"
            if isSymlink, let arrowRange = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrowRange.lowerBound])
            }

            // Skip . and ..
            guard name != "." && name != ".." else { continue }

            // Size is field 4 for files (0 or 4096 for directories)
            let size: UInt64 = UInt64(parts[4]) ?? 0

            // Date is fields 5+6: "2026-01-15 10:30"
            let dateStr = "\(parts[5]) \(parts[6])"
            let modDate = Self.lsDateFormatter.date(from: dateStr) ?? Date()

            let cleanParent = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
            let fullPath = "\(cleanParent)/\(name)"

            // Symlinks to directories should be treated as directories
            let effectiveIsDirectory = isDirectory || isSymlink

            let contentType: String
            if effectiveIsDirectory {
                contentType = "public.folder"
            } else {
                contentType = Self.extensionToUTType(name)
            }

            items.append(FileItem(
                id: fullPath,
                name: name,
                path: fullPath,
                isDirectory: effectiveIsDirectory,
                size: effectiveIsDirectory ? 0 : size,
                modificationDate: modDate,
                contentType: contentType
            ))
        }

        return items
    }

    /// Parse `adb pull` output to extract transferred byte count.
    ///
    /// Format: "file pulled, 0 skipped. 25.3 MB/s (808832 bytes in 0.030s)"
    private func parseADBPullSize(_ output: String) -> UInt64? {
        // Match "(NNNN bytes in" and capture only the digit group.
        // Using NSRegularExpression to get the capture group directly,
        // avoiding the "filter all digits" approach which would include
        // digits from the surrounding context if the pattern ever shifts.
        let pattern = #"\((\d+) bytes in"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let captureRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return UInt64(output[captureRange])
    }

    /// Parse `df` output to extract storage total and free.
    ///
    /// Format varies, but typically:
    /// ```
    /// Filesystem    1K-blocks    Used Available Use% Mounted on
    /// /dev/...      123456789 67890123  55566666  55% /storage/emulated
    /// ```
    private func parseDfOutput(_ output: String) -> (total: UInt64?, free: UInt64?) {
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2 else { return (nil, nil) }

        // Take the last non-empty line (the data line)
        let dataLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("Filesystem") })
        guard let line = dataLine else { return (nil, nil) }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return (nil, nil) }

        // Values are in 1K blocks
        let totalKB = UInt64(parts[1])
        let freeKB = UInt64(parts[3])

        return (total: totalKB.map { $0 * 1024 }, free: freeKB.map { $0 * 1024 })
    }

    /// Map file extension to UTType content type string.
    ///
    /// Delegates to FileTypeRegistry — single source of truth for all engines.
    private static func extensionToUTType(_ filename: String) -> String {
        FileTypeRegistry.utTypeString(for: filename)
    }

    // MARK: - ADB Process Runner

    /// Run an ADB command asynchronously.
    ///
    /// Uses `terminationHandler` to avoid blocking the actor's executor.
    /// A `NSLock`-guarded flag ensures the continuation is resumed exactly
    /// once even if `process.run()` throws AND the termination handler fires.
    private func runADB(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = arguments

            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            // Guard against the continuation being resumed more than once.
            // This can happen if process.run() throws synchronously AND the
            // termination handler fires (e.g. the process exits immediately).
            let lock = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let output): continuation.resume(returning: output)
                case .failure(let error):  continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { proc in
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    resumeOnce(.failure(ADBError.commandFailed(
                        command: arguments.joined(separator: " "),
                        exitCode: Int(proc.terminationStatus),
                        stderr: stderr
                    )))
                } else {
                    resumeOnce(.success(output))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(ADBError.commandFailed(
                    command: arguments.joined(separator: " "),
                    exitCode: -1,
                    stderr: error.localizedDescription
                )))
            }
        }
    }
}
