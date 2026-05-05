// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import CLibMTP
import os

/// MTP transfer engine backed by libmtp.
///
/// Wraps the libmtp C library in a Swift-friendly async interface.
/// Handles MTP session management, file enumeration, and single-file
/// transfer. All libmtp calls are serialized by the actor to satisfy
/// the library's single-threaded requirement.
///
/// libmtp is linked as a dynamic library (.dylib) for LGPL compliance.
actor MTPEngine: TransferEngine {

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "mtp"
    )

    /// MTP uses 0xFFFFFFFF as the parent ID for the storage root.
    private static let rootParentID: UInt32 = 0xFFFF_FFFF

    /// Typed pointer to the open MTP device session.
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>?

    /// Primary storage ID on the connected device.
    private var storageID: UInt32 = 0

    /// Ensures `LIBMTP_Init()` is called exactly once across all instances.
    /// Uses `nonisolated(unsafe)` because this is guarded by the lock below.
    nonisolated(unsafe) private static var libmtpInitialized = false
    private static let initLock = NSLock()

    var isConnected: Bool { device != nil }

    // MARK: - Lifecycle

    func connect(device usbDevice: USBDevice) async throws {
        logger.info("Connecting via MTP to \(usbDevice.displayName)")

        Self.initLibMTPOnce()

        // Detect raw devices on the bus.
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var numDevices: CInt = 0
        let detectResult = LIBMTP_Detect_Raw_Devices(&rawDevices, &numDevices)

        guard detectResult == LIBMTP_ERROR_NONE,
              let devices = rawDevices,
              numDevices > 0 else {
            logger.error("No MTP devices detected (code: \(detectResult.rawValue))")
            throw MTPError.deviceNotFound
        }
        defer { free(rawDevices) }

        // Find the device matching our vendor/product ID.
        var matchIndex: Int?
        for i in 0..<Int(numDevices) {
            let raw = devices[i]
            if raw.device_entry.vendor_id == usbDevice.vendorID,
               raw.device_entry.product_id == usbDevice.productID {
                matchIndex = i
                break
            }
        }

        // Fall back to the first device if no exact match.
        let index = matchIndex ?? 0
        logger.debug("Opening raw device at index \(index)")

        guard let mtpDevice = LIBMTP_Open_Raw_Device_Uncached(&devices[index]) else {
            logger.error("Failed to open MTP device session")
            throw MTPError.connectionFailed(
                device: usbDevice.displayName,
                reason: "LIBMTP_Open_Raw_Device_Uncached returned nil"
            )
        }

        self.device = mtpDevice

        // Fetch storage info so we know the primary storage ID.
        let storageResult = LIBMTP_Get_Storage(mtpDevice, LIBMTP_STORAGE_SORTBY_NOTSORTED)
        if storageResult == 0, let storage = mtpDevice.pointee.storage {
            self.storageID = storage.pointee.id
            let name = storage.pointee.StorageDescription
                .flatMap { String(cString: $0) } ?? "unnamed"
            let freeGB = storage.pointee.FreeSpaceInBytes / 1_073_741_824
            logger.info("Storage: \(name) (\(freeGB) GB free)")
        } else {
            logger.warning("Could not retrieve storage info — using default storage ID 0")
        }

        logger.info("MTP session established with \(usbDevice.displayName)")
    }

    func disconnect() async {
        logger.info("Disconnecting MTP session")
        if let dev = device {
            LIBMTP_Release_Device(dev)
        }
        device = nil
        storageID = 0
    }

    // MARK: - File Operations

    func listFiles(at path: String) async throws -> [FileItem] {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.debug("MTP listFiles at: \(path, privacy: .private(mask: .hash))")

        let folderID: UInt32
        if path == "/" || path.isEmpty {
            folderID = MTPEngine.rootParentID
        } else {
            guard let resolved = resolvePathToFolderID(path, storageID: storageID) else {
                throw MTPError.fileNotFound(path: path)
            }
            folderID = resolved
        }

        var items: [FileItem] = []
        let files = LIBMTP_Get_Files_And_Folders(dev, storageID, folderID)
        var node = files

        while let current = node {
            let file = current.pointee
            let name = file.filename.flatMap { String(cString: $0) } ?? "unknown"
            let isDir = file.filetype == LIBMTP_FILETYPE_FOLDER
            let contentType = isDir ? "public.folder" : mtpFileTypeToUTType(file.filetype)
            let modDate = Date(timeIntervalSince1970: TimeInterval(file.modificationdate))

            let parentPath = (path == "/" || path.isEmpty) ? "" : path
            let fullPath = "\(parentPath)/\(name)"

            items.append(FileItem(
                id: String(file.item_id),
                name: name,
                path: fullPath,
                isDirectory: isDir,
                size: file.filesize,
                modificationDate: modDate,
                contentType: contentType
            ))

            let next = current.pointee.next
            LIBMTP_destroy_file_t(current)
            node = next
        }

        logger.debug("Listed \(items.count) items at \(path, privacy: .private(mask: .hash))")
        return items
    }

    func readFile(at path: String, offset: UInt64, length: UInt64) async throws -> Data {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.debug("MTP readFile at: \(path, privacy: .private(mask: .hash))")

        // Resolve the file's object ID by walking the path.
        guard let fileID = resolvePathToObjectID(path, storageID: storageID) else {
            throw MTPError.fileNotFound(path: path)
        }

        // Create a temporary file to receive the data.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-mtp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fd = open(tempURL.path, O_RDWR)
        guard fd >= 0 else {
            throw MTPError.transferFailed(file: path, reason: "Could not create temp file")
        }
        // fd is closed explicitly after the libmtp write, before Data(contentsOf:).
        // Do NOT use defer { close(fd) } here — we close it manually below.

        let result = LIBMTP_Get_File_To_File_Descriptor(dev, fileID, fd, nil, nil)
        guard result == 0 else {
            // Close the fd before throwing — otherwise it leaks.
            // After ~1024 leaked fds the process hits EMFILE and all file ops fail.
            close(fd)
            let errStr = lastMTPError()
            logger.error("Transfer failed for \(path, privacy: .private(mask: .hash)): \(errStr)")
            throw MTPError.transferFailed(file: path, reason: errStr)
        }

        // Close the fd before reading via Data(contentsOf:) — both must not
        // hold the file open simultaneously, and Data needs a clean read from offset 0.
        close(fd)

        let data = try Data(contentsOf: tempURL)

        // Apply offset/length if the caller requested a sub-range.
        if offset == 0 && (length == UInt64.max || length >= UInt64(data.count)) {
            return data
        }
        let start = min(Int(offset), data.count)
        let end = min(start + Int(length), data.count)
        return data.subdata(in: start..<end)
    }

    /// Write a file to the Android device via MTP.
    ///
    /// MTP write requires three steps:
    /// 1. Resolve the destination folder path to an MTP object ID
    /// 2. Build an LIBMTP_file_t metadata struct (name, size, type, parent)
    /// 3. Call LIBMTP_Send_File_From_File — libmtp reads from a local path
    ///    and streams to the device
    ///
    /// The data is written to a temp file first so libmtp can read it by path.
    /// MTP requires the exact file size declared upfront, which is why we
    /// can't stream from an unknown source — we need the full size before
    /// sending the first byte.
    func writeFile(at path: String, data: Data) async throws {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.info("MTP writeFile: \(path, privacy: .private(mask: .hash)) (\(data.count) bytes)")

        // Split path into parent directory and filename
        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw MTPError.transferFailed(file: path, reason: "Invalid path")
        }

        let fileName = components.last!
        let dirComponents = Array(components.dropLast())

        // Resolve the parent folder to an MTP object ID
        let parentID: UInt32
        if dirComponents.isEmpty {
            parentID = MTPEngine.rootParentID
        } else {
            let dirPath = "/" + dirComponents.joined(separator: "/")
            guard let resolved = resolvePathToFolderID(dirPath, storageID: storageID) else {
                throw MTPError.fileNotFound(path: dirPath)
            }
            parentID = resolved
        }

        // Write data to a temp file — libmtp reads from a file path, not a buffer
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-mtp-send-\(UUID().uuidString)-\(fileName)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Build the LIBMTP_file_t metadata struct
        // libmtp takes ownership of the filename C string — we must strdup it
        guard let fileNameC = strdup(fileName) else {
            throw MTPError.transferFailed(file: path, reason: "strdup failed")
        }

        var fileInfo = LIBMTP_file_t()
        fileInfo.filename = fileNameC
        fileInfo.filesize = UInt64(data.count)
        fileInfo.filetype = mtpFileTypeFromExtension(fileName)
        fileInfo.parent_id = parentID
        fileInfo.storage_id = storageID
        fileInfo.item_id = 0       // assigned by device after send
        fileInfo.modificationdate = Int(Date().timeIntervalSince1970)
        fileInfo.next = nil

        // Send the file — libmtp reads from tempURL.path and streams to device
        let result = LIBMTP_Send_File_From_File(
            dev,
            tempURL.path,
            &fileInfo,
            nil,   // progress callback
            nil    // callback data
        )

        // Free the C string regardless of success or failure.
        // libmtp copies the filename internally during Send — our strdup copy
        // is no longer needed after the call returns.
        free(fileNameC)

        guard result == 0 else {
            let errStr = lastMTPError()
            logger.error("MTP writeFile failed for \(path, privacy: .private(mask: .hash)): \(errStr)")
            throw MTPError.transferFailed(file: path, reason: errStr)
        }

        logger.info("MTP writeFile complete: \(path, privacy: .private(mask: .hash))")
    }

    /// Delete a file on the Android device via MTP.
    ///
    /// Resolves the path to an MTP object ID, then calls LIBMTP_Delete_Object.
    func deleteFile(at path: String) async throws {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.info("MTP deleteFile: \(path, privacy: .private(mask: .hash))")

        guard let objectID = resolvePathToObjectID(path, storageID: storageID) else {
            throw MTPError.fileNotFound(path: path)
        }

        let result = LIBMTP_Delete_Object(dev, objectID)
        guard result == 0 else {
            let errStr = lastMTPError()
            logger.error("MTP deleteFile failed for \(path, privacy: .private(mask: .hash)): \(errStr)")
            throw MTPError.transferFailed(file: path, reason: errStr)
        }

        logger.info("MTP deleteFile complete: \(path, privacy: .private(mask: .hash))")
    }

    /// Rename a file on the Android device via MTP.
    ///
    /// MTP provides `LIBMTP_Set_File_Name` which renames a file object in-place
    /// without moving it. The file stays in the same directory.
    ///
    /// - Parameters:
    ///   - path: Current full path of the file on the device.
    ///   - newName: New filename only (not a full path).
    func renameFile(at path: String, to newName: String) async throws {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.info("MTP renameFile: \(path, privacy: .private(mask: .hash)) → \(newName, privacy: .private(mask: .hash))")

        guard let objectID = resolvePathToObjectID(path, storageID: storageID) else {
            throw MTPError.fileNotFound(path: path)
        }

        // Fetch the current file object so we can pass it to LIBMTP_Set_File_Name
        guard let fileObject = LIBMTP_Get_Filemetadata(dev, objectID) else {
            let errStr = lastMTPError()
            throw MTPError.transferFailed(file: path, reason: "Could not fetch file metadata: \(errStr)")
        }
        defer { LIBMTP_destroy_file_t(fileObject) }

        // LIBMTP_Set_File_Name takes the file object and the new name.
        // It frees and replaces the filename field internally.
        let result = newName.withCString { namePtr in
            LIBMTP_Set_File_Name(dev, fileObject, namePtr)
        }

        guard result == 0 else {
            let errStr = lastMTPError()
            logger.error("MTP renameFile failed for \(path, privacy: .private(mask: .hash)): \(errStr)")
            throw MTPError.transferFailed(file: path, reason: errStr)
        }

        logger.info("MTP renameFile complete: \(path, privacy: .private(mask: .hash))")
    }

    func pullFile(
        from remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UInt64 {
        guard let dev = device else { throw MTPError.deviceNotFound }
        logger.debug("MTP pullFile: \(remotePath, privacy: .private(mask: .hash)) → local")

        guard let fileID = resolvePathToObjectID(remotePath, storageID: storageID) else {
            throw MTPError.fileNotFound(path: remotePath)
        }

        // Ensure parent directory exists
        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Use LIBMTP_Get_File_To_File for direct-to-disk transfer.
        // This avoids loading the file into memory — libmtp writes directly
        // to the destination path.
        let result = LIBMTP_Get_File_To_File(
            dev,
            fileID,
            localURL.path,
            nil,  // progress callback (TODO: wire up in Phase 3)
            nil   // callback data
        )

        guard result == 0 else {
            let errStr = lastMTPError()
            logger.error("Pull failed for \(remotePath, privacy: .private(mask: .hash)): \(errStr)")
            throw MTPError.transferFailed(file: remotePath, reason: errStr)
        }

        // Get the size of the written file
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0

        progress?(fileSize)

        logger.debug("Pulled \(fileSize) bytes: \(remotePath, privacy: .private(mask: .hash))")
        return fileSize
    }

    // MARK: - Device Info

    func deviceInfo() async throws -> DeviceState {
        guard let dev = device else { throw MTPError.deviceNotFound }

        let model = extractCString(LIBMTP_Get_Modelname(dev)) ?? "MTP Device"
        let manufacturer = extractCString(LIBMTP_Get_Manufacturername(dev)) ?? "Unknown"
        let serial = extractCString(LIBMTP_Get_Serialnumber(dev)) ?? "unknown"

        var storageTotal: UInt64?
        var storageFree: UInt64?

        // Re-fetch storage to get current free space.
        let storageResult = LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED)
        if storageResult == 0, let storage = dev.pointee.storage {
            storageTotal = storage.pointee.MaxCapacity
            storageFree = storage.pointee.FreeSpaceInBytes
        }

        return DeviceState(
            serialNumber: serial,
            displayName: model,
            manufacturer: manufacturer,
            model: model,
            connectionStatus: .connected,
            engineType: .mtp,
            storageTotal: storageTotal,
            storageFree: storageFree
        )
    }

    func remoteChecksum(at path: String, algorithm: ChecksumAlgorithm) async throws -> String? {
        // MTP has no remote checksum capability.
        // Caller must pull the file and hash locally.
        nil
    }

    // MARK: - Path Resolution

    /// Resolve a device path like "/DCIM/Camera" to an MTP folder object ID.
    ///
    /// MTP uses object IDs, not paths. This walks the directory tree from the
    /// storage root, matching each path component by name.
    private func resolvePathToFolderID(_ path: String, storageID: UInt32) -> UInt32? {
        guard let dev = device else { return nil }

        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else {
            return MTPEngine.rootParentID
        }

        var currentParent = MTPEngine.rootParentID

        for component in components {
            var found = false
            let files = LIBMTP_Get_Files_And_Folders(dev, storageID, currentParent)
            var node = files

            while let current = node {
                let name = current.pointee.filename.flatMap { String(cString: $0) }
                let next = current.pointee.next

                if name == component && current.pointee.filetype == LIBMTP_FILETYPE_FOLDER {
                    currentParent = current.pointee.item_id
                    found = true
                    // Free the rest of the list.
                    destroyFileList(from: current)
                    break
                }

                LIBMTP_destroy_file_t(current)
                node = next
            }

            if !found {
                return nil
            }
        }

        return currentParent
    }

    /// Resolve a full file path to its MTP object ID.
    ///
    /// Splits the path into directory components and a filename, resolves the
    /// directory, then finds the file by name within that directory.
    private func resolvePathToObjectID(_ path: String, storageID: UInt32) -> UInt32? {
        guard let dev = device else { return nil }

        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return nil }

        let fileName = components.last!
        let dirComponents = Array(components.dropLast())

        let parentID: UInt32
        if dirComponents.isEmpty {
            parentID = MTPEngine.rootParentID
        } else {
            let dirPath = "/" + dirComponents.joined(separator: "/")
            guard let resolved = resolvePathToFolderID(dirPath, storageID: storageID) else {
                return nil
            }
            parentID = resolved
        }

        // Search for the file in the parent directory.
        let files = LIBMTP_Get_Files_And_Folders(dev, storageID, parentID)
        var node = files
        var result: UInt32?

        while let current = node {
            let name = current.pointee.filename.flatMap { String(cString: $0) }
            let next = current.pointee.next

            if name == fileName {
                result = current.pointee.item_id
                destroyFileList(from: current)
                break
            }

            LIBMTP_destroy_file_t(current)
            node = next
        }

        return result
    }

    // MARK: - Helpers

    /// Call `LIBMTP_Init()` exactly once, thread-safe across all instances.
    private static func initLibMTPOnce() {
        initLock.lock()
        defer { initLock.unlock() }
        if !libmtpInitialized {
            LIBMTP_Init()
            libmtpInitialized = true
        }
    }

    deinit {
        // Actor deinit runs on the actor's executor, so accessing
        // `device` is safe here. If the caller forgot to disconnect,
        // release the MTP session to avoid leaking the USB handle.
        if let dev = device {
            LIBMTP_Release_Device(dev)
        }
    }

    /// Extract a Swift `String` from a C string returned by libmtp, then free it.
    private func extractCString(_ cStr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = cStr else { return nil }
        let str = String(cString: ptr)
        free(ptr)
        return str
    }

    /// Get the last error message from the MTP device error stack.
    private func lastMTPError() -> String {
        guard let dev = device else { return "no device" }
        var errNode = LIBMTP_Get_Errorstack(dev)
        var messages: [String] = []
        while let err = errNode {
            if let text = err.pointee.error_text {
                messages.append(String(cString: text))
            }
            errNode = err.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        return messages.isEmpty ? "unknown error" : messages.joined(separator: "; ")
    }

    /// Free an entire linked list of `LIBMTP_file_t` starting from the given node.
    private func destroyFileList(from head: UnsafeMutablePointer<LIBMTP_file_struct>?) {
        var node = head
        while let current = node {
            let next = current.pointee.next
            LIBMTP_destroy_file_t(current)
            node = next
        }
    }

    /// Map a filename extension to an MTP file type constant.
    ///
    /// MTP requires a file type in the object info struct when sending files.
    /// LIBMTP_FILETYPE_UNKNOWN is the correct fallback — devices handle it
    /// gracefully and store the file regardless.
    private func mtpFileTypeFromExtension(_ filename: String) -> LIBMTP_filetype_t {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        // Images
        case "jpg", "jpeg":         return LIBMTP_FILETYPE_JPEG
        case "png":                 return LIBMTP_FILETYPE_PNG
        case "gif":                 return LIBMTP_FILETYPE_GIF
        case "bmp":                 return LIBMTP_FILETYPE_BMP
        case "tiff", "tif":         return LIBMTP_FILETYPE_TIFF
        // Video
        case "mp4", "m4v":          return LIBMTP_FILETYPE_MP4
        case "mov":                 return LIBMTP_FILETYPE_QT
        case "avi":                 return LIBMTP_FILETYPE_AVI
        case "wmv":                 return LIBMTP_FILETYPE_WMV
        case "asf":                 return LIBMTP_FILETYPE_ASF
        case "3gp":                 return LIBMTP_FILETYPE_MP4  // closest MTP type
        // Audio
        case "mp3":                 return LIBMTP_FILETYPE_MP3
        case "wav":                 return LIBMTP_FILETYPE_WAV
        case "wma":                 return LIBMTP_FILETYPE_WMA
        case "aac", "m4a":          return LIBMTP_FILETYPE_AAC
        case "flac":                return LIBMTP_FILETYPE_FLAC
        case "ogg":                 return LIBMTP_FILETYPE_OGG
        // Documents
        case "txt":                 return LIBMTP_FILETYPE_TEXT
        case "xml":                 return LIBMTP_FILETYPE_XML
        case "html", "htm":         return LIBMTP_FILETYPE_HTML
        case "doc", "docx":         return LIBMTP_FILETYPE_DOC
        // Everything else — device stores it as generic binary
        default:                    return LIBMTP_FILETYPE_UNKNOWN
        }
    }

    /// Map an MTP file type to a UTType content type identifier string.
    ///
    /// MTP gives us a type enum, not a filename. We map the enum to a
    /// canonical extension first, then delegate to FileTypeRegistry
    /// so the UTType strings stay in one place.
    private func mtpFileTypeToUTType(_ fileType: LIBMTP_filetype_t) -> String {
        // Map MTP type constant → a representative extension, then look up in registry.
        // For types with no registry entry, fall back to "public.data".
        let ext: String
        switch fileType {
        case LIBMTP_FILETYPE_JPEG, LIBMTP_FILETYPE_JFIF: ext = "jpg"
        case LIBMTP_FILETYPE_PNG:   ext = "png"
        case LIBMTP_FILETYPE_BMP:   ext = "bmp"
        case LIBMTP_FILETYPE_GIF:   ext = "gif"
        case LIBMTP_FILETYPE_TIFF:  ext = "tiff"
        case LIBMTP_FILETYPE_MP4:   ext = "mp4"
        case LIBMTP_FILETYPE_AVI:   ext = "avi"
        case LIBMTP_FILETYPE_WMV:   ext = "wmv"
        case LIBMTP_FILETYPE_ASF:   ext = "asf"
        case LIBMTP_FILETYPE_QT:    ext = "mov"
        case LIBMTP_FILETYPE_MP3:   ext = "mp3"
        case LIBMTP_FILETYPE_WAV:   ext = "wav"
        case LIBMTP_FILETYPE_WMA:   ext = "wma"
        case LIBMTP_FILETYPE_AAC:   ext = "aac"
        case LIBMTP_FILETYPE_FLAC:  ext = "flac"
        case LIBMTP_FILETYPE_OGG:   ext = "ogg"
        case LIBMTP_FILETYPE_M4A:   ext = "m4a"
        case LIBMTP_FILETYPE_DOC:   ext = "doc"
        case LIBMTP_FILETYPE_XML:   ext = "xml"
        case LIBMTP_FILETYPE_TEXT:  ext = "txt"
        case LIBMTP_FILETYPE_HTML:  ext = "html"
        case LIBMTP_FILETYPE_FOLDER: return "public.folder"
        default:                    return "public.data"
        }
        return FileTypeRegistry.utTypeByExtension[ext] ?? "public.data"
    }
}
