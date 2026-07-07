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
/// All process spawning is async via `withCheckedThrowingContinuation`.
actor ADBEngine: TransferEngine {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "adb"
    )

    nonisolated(unsafe) private var connected = false
    nonisolated(unsafe) private var deviceSerial: String?

    private let adbPath: String

    init() {
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

        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            throw ADBError.binaryNotFound
        }

        _ = try? await runADB(["start-server"])
        let devicesOutput = try await runADB(["devices", "-l"])

        // Use the fast C parser for device list parsing
        let parsedDevices = FastADBParser.parseDevices(devicesOutput)

        var foundSerial: String?

        for dev in parsedDevices {
            if dev.isUnauthorized {
                if dev.serial == device.serialNumber || foundSerial == nil {
                    throw ADBError.deviceNotAuthorized(device: device.displayName)
                }
                continue
            }

            // Match by serial if possible, otherwise take the first online device
            if dev.serial == device.serialNumber {
                foundSerial = dev.serial
                break
            } else if dev.isOnline && foundSerial == nil {
                foundSerial = dev.serial
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

        let output = try await runADB([
            "-s", serial, "shell",
            "ls", "-la", path
        ])

        // Use C parser for large directories (3-10x faster than Swift string splitting)
        if output.count > 5000 {
            return FastLsParser.parse(output: output, parentPath: path)
        }

        return parseLsOutput(output, parentPath: path)
    }

    func readFile(at path: String, offset: UInt64, length: UInt64) async throws -> Data {
        let serial = try requireSerial()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-adb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await runADB(["-s", serial, "pull", path, tempURL.path])
        let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)

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

        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let output = try await runADB(["-s", serial, "pull", remotePath, localURL.path])
        let fileSize = FastADBParser.parsePullOutput(output)?.bytesTransferred ?? 0

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
        return actualSize
    }

    /// Pull an entire directory in one `adb pull` call.
    func pullDirectory(from remoteDir: String, to localDir: URL) async throws -> UInt64 {
        let serial = try requireSerial()
        logger.info("ADB pullDirectory: \(remoteDir, privacy: .private(mask: .hash))")

        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let remoteDirSlash = remoteDir.hasSuffix("/") ? remoteDir : remoteDir + "/"
        let output = try await runADB(["-s", serial, "pull", remoteDirSlash, localDir.path])

        let totalBytes = FastADBParser.parsePullOutput(output)?.bytesTransferred ?? 0
        if totalBytes == 0 {
            return directorySize(at: localDir)
        }
        return totalBytes
    }

    /// Sync a directory — `adb pull` skips files that haven't changed.
    func syncDirectory(from remoteDir: String, to localDir: URL) async throws -> UInt64 {
        let serial = try requireSerial()
        logger.info("ADB syncDirectory: \(remoteDir, privacy: .private(mask: .hash))")

        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let remoteDirSlash = remoteDir.hasSuffix("/") ? remoteDir : remoteDir + "/"
        let output = try await runADB(["-s", serial, "pull", remoteDirSlash, localDir.path])

        return FastADBParser.parsePullOutput(output)?.bytesTransferred ?? 0
    }

    private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    func writeFile(at path: String, data: Data) async throws {
        let serial = try requireSerial()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-adb-push-\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try await runADB(["-s", serial, "push", tempURL.path, path])
    }

    func writeFile(
        at remotePath: String,
        from localURL: URL,
        progress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UInt64 {
        let serial = try requireSerial()
        // `adb push` takes a path directly, so we don't need to stage or copy.
        // Progress callback isn't wired through — `adb push` writes its own
        // progress line to stdout, we could parse it later if users want
        // live progress for ADB, but MTP is the primary engine.
        let output = try await runADB(["-s", serial, "push", localURL.path, remotePath])
        let pushed = FastADBParser.parsePullOutput(output)?.bytesTransferred
        if let pushed { progress?(pushed) }

        if let pushed, pushed > 0 { return pushed }
        if let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? UInt64 {
            progress?(size)
            return size
        }
        return 0
    }

    func deleteFile(at path: String) async throws {
        let serial = try requireSerial()
        _ = try await runADB(["-s", serial, "shell", "rm", "-f", path])
    }

    /// Rename a file on the device (same directory, new filename).
    func renameFile(at path: String, to newName: String) async throws {
        let serial = try requireSerial()

        let directory = (path as NSString).deletingLastPathComponent
        let newPath = (directory as NSString).appendingPathComponent(newName)
        _ = try await runADB(["-s", serial, "shell", "mv", path, newPath])
    }

    // MARK: - Device Info

    func deviceInfo() async throws -> DeviceState {
        let serial = try requireSerial()

        let model = (try? await shellGetProp(serial: serial, prop: "ro.product.model")) ?? "ADB Device"
        let manufacturer = (try? await shellGetProp(serial: serial, prop: "ro.product.manufacturer")) ?? "Unknown"

        var storageTotal: UInt64?
        var storageFree: UInt64?
        if let dfOutput = try? await runADB(["-s", serial, "shell", "df", "/storage/emulated/0"]) {
            if let parsed = FastADBParser.parseDf(dfOutput) {
                storageTotal = parsed.total
                storageFree = parsed.free
            }
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

    private func requireSerial() throws(ADBError) -> String {
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
            os_log(.error, log: OSLog(subsystem: "com.snaphaul.app", category: "adb"),
                   "ADBEngine deallocated while still connected [%{public}@]", redacted)
        }
    }

    private func shellGetProp(serial: String, prop: String) async throws -> String {
        let output = try await runADB(["-s", serial, "shell", "getprop", prop])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output Parsing

    /// Cached date formatter for `ls -la` output parsing.
    private static let lsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parse `ls -la` output into FileItem array.
    private func parseLsOutput(_ output: String, parentPath: String) -> [FileItem] {
        var items: [FileItem] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("total"),
                  !trimmed.hasPrefix("ls:") else { continue }

            let parts = trimmed.split(
                separator: " ",
                maxSplits: 7,
                omittingEmptySubsequences: true
            ).map(String.init)

            guard parts.count >= 8 else { continue }

            let permissions = parts[0]
            let isDirectory = permissions.hasPrefix("d")
            let isSymlink = permissions.hasPrefix("l")

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

            guard name != "." && name != ".." else { continue }

            let size: UInt64 = UInt64(parts[4]) ?? 0

            let dateStr = "\(parts[5]) \(parts[6])"
            let modDate = Self.lsDateFormatter.date(from: dateStr) ?? Date()

            let cleanParent = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
            let fullPath = "\(cleanParent)/\(name)"

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

    /// Map file extension to UTType content type string.
    private static func extensionToUTType(_ filename: String) -> String {
        FileTypeRegistry.utTypeString(for: filename)
    }

    // MARK: - ADB Process Runner

    /// Run an ADB command asynchronously.
    private func runADB(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = arguments

            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            // Use a class-based box to safely share mutable state across
            // the @Sendable closure boundary. The NSLock serializes access.
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }

            let state = ResumeState()

            process.terminationHandler = { proc in
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                guard state.tryResume() else { return }

                if proc.terminationStatus != 0 {
                    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ADBError.commandFailed(
                        command: arguments.joined(separator: " "),
                        exitCode: Int(proc.terminationStatus),
                        stderr: stderr
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
            } catch {
                guard state.tryResume() else { return }
                continuation.resume(throwing: ADBError.commandFailed(
                    command: arguments.joined(separator: " "),
                    exitCode: -1,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}
