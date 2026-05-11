 // SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import SnapHaulKit
import CMTPCore
import os

/// Native MTP engine using CMTPCore + libusb USB transport.
///
/// Replaces libmtp with a pure C/Swift MTP stack. USB I/O is performed via
/// libusb-1.0 (user-space USB access). The C layer (CMTPCore) handles MTP
/// protocol framing, session management, and bulk data transfer.
actor MTPNativeEngine: TransferEngine {

    private let logger = Logger(subsystem: "com.snaphaul.app", category: "mtp-native")

    /// Marked nonisolated(unsafe) to allow cleanup check in deinit — safe because
    /// deinit only runs when no other references exist.
    nonisolated(unsafe) private var session: UnsafeMutablePointer<mtp_session_t>?
    private var deviceSerial: String = ""
    private var deviceModel: String = ""
    private var deviceManufacturer: String = ""
    private var primaryStorageID: UInt32 = 0

    /// All discovered storage IDs (internal + SD card).
    private var storageIDs: [UInt32] = []

    /// Storage metadata for UI display.
    struct StorageEntry: Sendable {
        let id: UInt32
        let name: String
        let totalBytes: UInt64
        let freeBytes: UInt64
    }
    private(set) var storages: [StorageEntry] = []

    private var transportContext: UnsafeMutableRawPointer?
    private var vendorID: UInt16 = 0

    /// Object handle cache: path → handle.
    private var handleCache: [String: UInt32] = [:]

    /// Keep-alive task — interval adjusted per vendor quirks.
    private var keepAliveTask: Task<Void, Never>?

    /// Device quirk profile — loaded after connection.
    private var deviceProfile: DeviceQuirks.DeviceProfile = DeviceQuirks.profile(for: 0)

    private static let mtpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var isConnected: Bool { session != nil && session!.pointee.is_open != 0 }

    /// IOUSBHost transport instance — used when io_service_t is available.
    /// Retained for the lifetime of the connection to keep pipes alive.
    private var ioUSBHostTransport: IOUSBHostTransport?

    // MARK: - Connection

    func connect(device: USBDevice) async throws {
        logger.info("Connecting via native MTP to \(device.displayName)")

        var usbInterface = mtp_usb_interface_t()

        // Strategy: IOUSBHost transport requires com.apple.vm.device-access entitlement
        // (paid Apple Developer account + Apple approval). Disabled until entitlement is granted.
        // When ready, set useIOUSBHost = true to enable the native path.
        let useIOUSBHost = false

        if useIOUSBHost && device.ioService != 0 {
            do {
                try await connectViaIOUSBHost(device: device, usbInterface: &usbInterface)
                logger.info("Connected via IOUSBHost transport (native)")
            } catch {
                logger.warning("IOUSBHost transport failed: \(error.localizedDescription, privacy: .public) — falling back to libusb")
                // Release the IOUSBHost transport if partially initialized
                ioUSBHostTransport?.close()
                ioUSBHostTransport = nil
                // Fall through to libusb path
                try await connectViaLibUSB(device: device, usbInterface: &usbInterface)
            }
        } else {
            // libusb path (default until entitlement is available)
            try await connectViaLibUSB(device: device, usbInterface: &usbInterface)
        }

        // Create MTP session using the USB callbacks provided by the transport
        guard let mtpSession = mtp_session_create(4 * 1024 * 1024, usbInterface) else {
            closeTransport()
            throw MTPError.connectionFailed(device: device.displayName, reason: "Failed to allocate MTP session")
        }
        self.session = mtpSession

        guard mtp_open_session(mtpSession) == 0 else {
            let error = safeString(from: mtpSession.pointee.last_error)
            mtp_session_destroy(mtpSession)
            self.session = nil
            closeTransport()
            throw MTPError.connectionFailed(device: device.displayName, reason: error)
        }

        if mtp_get_device_info_parsed(mtpSession) == 0 {
            let opCount = Int(mtpSession.pointee.supported_ops_count)
            logger.info("Device advertises \(opCount) supported MTP operations")
        } else {
            logger.warning("GetDeviceInfo parse failed: \(self.safeString(from: mtpSession.pointee.last_error), privacy: .public)")
        }

        // Discover all storages (internal + SD card)
        let storageCount = mtp_get_storage_ids(mtpSession)
        if storageCount > 0 {
            storageIDs = []
            storages = []

            for i in 0..<Int(storageCount) {
                let sid = withUnsafeBytes(of: mtpSession.pointee.storage_ids) { buf in
                    buf.load(fromByteOffset: i * MemoryLayout<UInt32>.size, as: UInt32.self)
                }
                storageIDs.append(sid)

                var storageInfo = mtp_storage_info_t()
                if mtp_get_storage_info(mtpSession, sid, &storageInfo) == 0 {
                    let desc = safeString(from: storageInfo.description)
                    storages.append(StorageEntry(
                        id: sid,
                        name: desc.isEmpty ? "Storage \(i + 1)" : desc,
                        totalBytes: storageInfo.max_capacity,
                        freeBytes: storageInfo.free_space
                    ))
                    let freeGB = storageInfo.free_space / 1_073_741_824
                    logger.info("Storage \(i): \(desc) (\(freeGB) GB free)")
                }
            }

            primaryStorageID = storageIDs.first ?? 0
        }

        self.deviceSerial = device.serialNumber
        self.deviceModel = device.displayName
        self.deviceManufacturer = device.manufacturer
        self.vendorID = device.vendorID
        self.handleCache = ["/": 0xFFFFFFFF]

        // Load vendor-specific quirk profile (with model-level overrides)
        self.deviceProfile = DeviceQuirks.profile(for: device.vendorID, productName: device.displayName)
        if !deviceProfile.quirks.isEmpty {
            logger.info("Quirks loaded for \(self.deviceProfile.vendorName): \(String(describing: self.deviceProfile.quirks))")
        }
        if DeviceQuirks.shouldPreferADB(vendorID: device.vendorID, productName: device.displayName) {
            logger.info("ADB recommended for \(self.deviceProfile.vendorName) — MTP is slow on this device")
        }

        startKeepAlive()
        logger.info("Native MTP session established with \(device.displayName)")
    }

    // MARK: - IOUSBHost Transport Path

    /// Connect using Apple's native IOUSBHost framework with device capture.
    /// This forcefully detaches PTPCamera and other macOS drivers — no need to kill processes.
    private func connectViaIOUSBHost(device: USBDevice, usbInterface: inout mtp_usb_interface_t) async throws {
        logger.info("Attempting IOUSBHost transport for VID=\(String(format: "%04x", device.vendorID)) PID=\(String(format: "%04x", device.productID))")

        let transport = IOUSBHostTransport()
        try transport.open(ioService: io_service_t(device.ioService))
        self.ioUSBHostTransport = transport

        usbInterface = transport.makeUSBInterface()
    }

    // MARK: - libusb Transport Path (Fallback)

    /// Connect using libusb — the legacy path. Requires killing PTPCamera first.
    private func connectViaLibUSB(device: USBDevice, usbInterface: inout mtp_usb_interface_t) async throws {
        // Kill macOS PTPCamera daemon that auto-claims Android MTP/PTP interfaces.
        // Without this, OpenSession fails ~30% of the time on first connection because
        // Image Capture.app's background agent holds the USB interface.
        await releasePTPCamera()

        var transportCtx: UnsafeMutableRawPointer?

        logger.info("Opening libusb transport for VID=\(String(format: "%04x", device.vendorID)) PID=\(String(format: "%04x", device.productID))")

        let usbResult = mtp_usb_transport_open(
            device.vendorID,
            device.productID,
            &usbInterface,
            &transportCtx
        )

        guard usbResult == 0, let ctx = transportCtx else {
            let errMsg: String
            if let transportCtx {
                errMsg = String(cString: mtp_usb_transport_error(transportCtx))
                mtp_usb_transport_close(transportCtx)
            } else {
                errMsg = "USB transport allocation failed"
            }
            logger.error("libusb transport open failed: \(errMsg, privacy: .public)")
            throw MTPError.connectionFailed(device: device.displayName, reason: errMsg)
        }
        self.transportContext = ctx
    }

    /// Close whichever transport is active (IOUSBHost or libusb).
    private func closeTransport() {
        if let transport = ioUSBHostTransport {
            transport.close()
            ioUSBHostTransport = nil
        }
        if let ctx = transportContext {
            mtp_usb_transport_close(ctx)
            transportContext = nil
        }
    }

    func disconnect() async {
        logger.info("Disconnecting native MTP session")
        stopKeepAlive()

        if let s = session {
            _ = mtp_close_session(s)
            mtp_session_destroy(s)
        }
        session = nil
        handleCache.removeAll()

        closeTransport()
    }

    // MARK: - Keep-Alive

    private func startKeepAlive() {
        let interval = DeviceQuirks.keepAliveInterval(for: vendorID)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.sendKeepAlivePing()
            }
        }
    }

    private func sendKeepAlivePing() {
        guard let s = session else { return }
        _ = mtp_get_storage_ids(s)
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: - File Operations

    func listFiles(at path: String) async throws -> [FileItem] {
        guard let s = session else { throw MTPError.deviceNotFound }

        let parentHandle = try resolvePathToHandle(path)

        var handles = [UInt32](repeating: 0, count: 10000)
        let count = mtp_get_object_handles(
            s, primaryStorageID, parentHandle, 0,
            &handles, Int32(handles.count)
        )
        guard count >= 0 else { throw MTPError.fileNotFound(path: path) }
        if count == 0 { return [] }

        var infos = [mtp_object_info_t](repeating: mtp_object_info_t(), count: Int(count))
        let infoCount: Int32

        // Apply inter-operation delay for vendors with flaky MTP stacks (Xiaomi, Huawei)
        if deviceProfile.interOpDelay > 0 {
            // For devices that need delays, fetch infos one at a time with pauses
            var success: Int32 = 0
            for i in 0..<Int(count) {
                if mtp_get_object_info(s, handles[i], &infos[i]) == 0 { success += 1 }
                if i % 50 == 49 {
                    try? await Task.sleep(nanoseconds: UInt64(deviceProfile.interOpDelay) * 1_000_000)
                }
            }
            infoCount = success
        } else {
            infoCount = mtp_get_object_info_batch(s, &handles, &infos, count)
        }

        var items: [FileItem] = []
        items.reserveCapacity(Int(infoCount))

        for i in 0..<Int(infoCount) {
            let info = infos[i]
            let name = safeString(from: info.filename)
            guard !name.isEmpty else { continue }

            let isDir = info.object_format == MTP_FORMAT_ASSOCIATION || info.association_type != 0
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"

            handleCache[fullPath] = info.object_handle

            let modDate = parseMTPDate(info.date_modified) ?? Date()
            let contentType = isDir ? "public.folder" : FileTypeRegistry.utTypeString(for: name)

            items.append(FileItem(
                id: String(info.object_handle),
                name: name,
                path: fullPath,
                isDirectory: isDir,
                size: isDir ? 0 : info.object_size_64,
                modificationDate: modDate,
                contentType: contentType
            ))
        }

        return items
    }

    func readFile(at path: String, offset: UInt64, length: UInt64) async throws -> Data {
        guard let s = session else { throw MTPError.deviceNotFound }
        let handle = try resolveFileHandle(path)

        let usePartialRead = offset > 0 || (length != UInt64.max)
        let exceeds32Bit = offset > 0xFFFFFFFF || length > 0xFFFFFFFF

        if usePartialRead && !DeviceQuirks.shouldAvoidPartialObject(vendorID: vendorID) {

            // 64-bit path for large files (4K/8K video > 4 GB)
            if exceeds32Bit {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("snaphaul-mtp-partial64-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tempURL) }
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let fd = open(tempURL.path, O_RDWR)
                guard fd >= 0 else {
                    throw MTPError.transferFailed(file: path, reason: "Could not create temp file")
                }
                var bytesWritten: UInt64 = 0
                let result = mtp_get_partial_object_64_to_fd(s, handle, offset, length, fd, &bytesWritten)
                close(fd)
                if result == 0 {
                    return try Data(contentsOf: tempURL, options: .mappedIfSafe)
                }
                // Fall through to full GetObject if 64-bit not supported
                logger.warning("GetPartialObject64 failed, falling back to full GetObject")
            }

            // 32-bit partial read path
            if !exceeds32Bit && offset <= 0xFFFFFFFF && length <= 0xFFFFFFFF {
                var readLength = length

                if deviceProfile.quirks.contains(.samsungPartialObjectBug) {
                    var objInfo = mtp_object_info_t()
                    if mtp_get_object_info(s, handle, &objInfo) == 0 {
                        let fileSize = objInfo.object_size_64
                        if let safeLen = DeviceQuirks.samsungSafePartialReadLength(
                            fileSize: fileSize, offset: offset, requestedLength: length) {
                            readLength = safeLen
                        }
                    }
                }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("snaphaul-mtp-partial-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tempURL) }
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let fd = open(tempURL.path, O_RDWR)
                guard fd >= 0 else {
                    throw MTPError.transferFailed(file: path, reason: "Could not create temp file")
                }
                var bytesWritten: UInt64 = 0
                let result = mtp_get_partial_object_to_fd(s, handle, offset, readLength, fd, &bytesWritten)

                if result == 0 && readLength < length {
                    var extraByte: UInt64 = 0
                    _ = mtp_get_partial_object_to_fd(s, handle, offset + readLength, 1, fd, &extraByte)
                    bytesWritten += extraByte
                }
                close(fd)

                guard result == 0 else {
                    throw MTPError.transferFailed(file: path, reason: lastError())
                }
                return try Data(contentsOf: tempURL, options: .mappedIfSafe)
            }
        }

        // Full GetObject — download entire file, slice in memory
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-mtp-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fd = open(tempURL.path, O_RDWR)
        guard fd >= 0 else {
            throw MTPError.transferFailed(file: path, reason: "Could not create temp file")
        }
        var bytesWritten: UInt64 = 0
        let result = mtp_get_object_to_fd(s, handle, fd, UInt64.max, &bytesWritten, nil, nil)
        close(fd)

        guard result == 0 else {
            throw MTPError.transferFailed(file: path, reason: lastError())
        }

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
        guard let s = session else { throw MTPError.deviceNotFound }
        let handle = try resolveFileHandle(remotePath)

        var info = mtp_object_info_t()
        guard mtp_get_object_info(s, handle, &info) == 0 else {
            throw MTPError.fileNotFound(path: remotePath)
        }
        let fileSize = info.object_size_64

        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let fd = open(localURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0644)
        guard fd >= 0 else {
            throw MTPError.transferFailed(file: remotePath, reason: "Could not create destination file")
        }

        _ = fcntl(fd, F_NOCACHE, 1)

        if fileSize >= 1_048_576 {
            var fst = fstore_t()
            fst.fst_flags = UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL)
            fst.fst_posmode = Int32(F_PEOFPOSMODE)
            fst.fst_length = Int64(fileSize)
            if fcntl(fd, F_PREALLOCATE, &fst) < 0 {
                fst.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(fd, F_PREALLOCATE, &fst)
            }
        }

        var bytesWritten: UInt64 = 0

        let result: Int32
        if let progress {
            var progressClosure = progress
            result = withUnsafeMutablePointer(to: &progressClosure) { closurePtr in
                mtp_get_object_to_fd(
                    s, handle, fd, fileSize, &bytesWritten,
                    { bytesSoFar, ctx in
                        guard let ctx else { return }
                        ctx.assumingMemoryBound(to: (@Sendable (UInt64) -> Void).self).pointee(bytesSoFar)
                    },
                    closurePtr
                )
            }
        } else {
            result = mtp_get_object_to_fd(s, handle, fd, fileSize, &bytesWritten, nil, nil)
        }

        if bytesWritten != fileSize { ftruncate(fd, Int64(bytesWritten)) }
        close(fd)

        guard result == 0 else {
            try? FileManager.default.removeItem(at: localURL)
            throw MTPError.transferFailed(file: remotePath, reason: lastError())
        }

        // Restore original modification date from device metadata
        let modDate = parseMTPDate(info.date_modified)
        if let date = modDate {
            try? FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: localURL.path
            )
        }

        return bytesWritten
    }

    func writeFile(at path: String, data: Data) async throws {
        guard let s = session else { throw MTPError.deviceNotFound }

        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw MTPError.transferFailed(file: path, reason: "Invalid path")
        }

        let rawFileName = components.last!

        if FileNameUtils.shouldSkip(rawFileName) {
            logger.debug("Skipping system file: \(rawFileName, privacy: .public)")
            return
        }

        let fileName = FileNameUtils.sanitizeForMTP(rawFileName)

        let parentPath = components.count > 1 ? "/" + components.dropLast().joined(separator: "/") : "/"

        let parentHandle: UInt32
        do {
            parentHandle = try resolvePathToHandle(parentPath)
        } catch {
            // Parent directory doesn't exist — create it recursively
            parentHandle = try createDirectoryRecursive(at: parentPath)
        }

        // Delete existing file if present — MTP has no in-place overwrite
        let targetPath = parentPath == "/" ? "/\(fileName)" : "\(parentPath)/\(fileName)"
        if let existingHandle = handleCache[targetPath] {
            _ = mtp_delete_object(s, existingHandle)
            handleCache.removeValue(forKey: targetPath)
            logger.debug("Deleted existing file before overwrite: \(fileName, privacy: .public)")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-mtp-send-\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let srcFD = open(tempURL.path, O_RDONLY)
        guard srcFD >= 0 else {
            throw MTPError.transferFailed(file: path, reason: "Could not open temp file")
        }
        defer { close(srcFD) }

        _ = try sendObjectFromFD(
            srcFD: srcFD,
            fileSize: UInt64(data.count),
            fileName: fileName,
            parentHandle: parentHandle,
            targetPath: path,
            progress: nil
        )
    }

    func writeFile(
        at remotePath: String,
        from localURL: URL,
        progress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UInt64 {
        guard session != nil else { throw MTPError.deviceNotFound }

        let components = remotePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw MTPError.transferFailed(file: remotePath, reason: "Invalid path")
        }

        let rawFileName = components.last!
        if FileNameUtils.shouldSkip(rawFileName) {
            logger.debug("Skipping system file: \(rawFileName, privacy: .public)")
            return 0
        }
        let fileName = FileNameUtils.sanitizeForMTP(rawFileName)
        let parentPath = components.count > 1
            ? "/" + components.dropLast().joined(separator: "/")
            : "/"

        let parentHandle: UInt32
        do {
            parentHandle = try resolvePathToHandle(parentPath)
        } catch {
            parentHandle = try createDirectoryRecursive(at: parentPath)
        }

        let targetPath = parentPath == "/" ? "/\(fileName)" : "\(parentPath)/\(fileName)"
        if let existingHandle = handleCache[targetPath] {
            _ = mtp_delete_object(session, existingHandle)
            handleCache.removeValue(forKey: targetPath)
            logger.debug("Deleted existing file before overwrite: \(fileName, privacy: .public)")
        }

        let preflight = FilePreflight.inspect(url: localURL)
        FilePreflight.log(preflight, logger: logger)

        guard preflight.exists else {
            throw MTPError.transferFailed(file: remotePath, reason: "Source file does not exist: \(localURL.path)")
        }

        let fileSize = preflight.fileSize ?? 0
        guard fileSize > 0 else {
            throw MTPError.transferFailed(file: remotePath, reason: "Source file is empty: \(localURL.path)")
        }

        let srcFD = open(localURL.path, O_RDONLY)
        guard srcFD >= 0 else {
            let openErrno = Foundation.errno
            let message = """
            Could not open source file: \(String(cString: strerror(openErrno))) \
            (errno=\(openErrno)) \
            — path: \(localURL.path) \
            — preflight: readable=\(preflight.readable), mode=\(preflight.posixPermissions.map { String(format: "0%o", $0) } ?? "?"), \
            quarantined=\(preflight.hasQuarantine), xattrs=[\(preflight.xattrNames.joined(separator: ","))]
            """
            logger.error("\(message, privacy: .public)")
            throw MTPError.transferFailed(file: remotePath, reason: message)
        }
        defer { close(srcFD) }

        _ = fcntl(srcFD, F_NOCACHE, 1)
        _ = fcntl(srcFD, F_RDAHEAD, 1)

        let sent = try sendObjectFromFD(
            srcFD: srcFD,
            fileSize: fileSize,
            fileName: fileName,
            parentHandle: parentHandle,
            targetPath: remotePath,
            progress: progress
        )

        progress?(sent)

        return sent
    }

    /// Core SendObjectInfo/OPL logic shared by both writeFile entry points.
    /// Returns bytes sent on success; throws on failure. Updates handleCache.
    ///
    /// The optional `progress` closure is invoked once per USB chunk (4 MB)
    /// during Phase 2 (SendObject) with bytes-sent-so-far. The closure runs
    /// synchronously on the actor's executor — hop to @MainActor inside if
    /// the callee needs UI updates. Keep it fast: this is called ~500 times
    /// for a 2 GB push and any blocking work here throttles USB throughput.
    private func sendObjectFromFD(
        srcFD: Int32,
        fileSize: UInt64,
        fileName: String,
        parentHandle: UInt32,
        targetPath: String,
        progress: (@Sendable (UInt64) -> Void)?
    ) throws -> UInt64 {
        guard let s = session else { throw MTPError.deviceNotFound }

        var newHandle: UInt32 = 0
        let format = mtpFormatFromExtension(fileName)

        let deviceAdvertisesOPL = mtp_operation_supported(s, UInt16(MTP_OP_SEND_OBJECT_PROP_LIST)) == 1
        let oplQuirkBroken = deviceProfile.quirks.contains(.brokenSendObjectPropList)
        let useOPL = deviceAdvertisesOPL && !oplQuirkBroken

        let runSend: (Bool) -> Int32 = { [self] legacy in
            if let progress {
                var progressClosure = progress
                return withUnsafeMutablePointer(to: &progressClosure) { closurePtr in
                    let cb: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { bytesSoFar, ctx in
                        guard let ctx else { return }
                        ctx.assumingMemoryBound(to: (@Sendable (UInt64) -> Void).self).pointee(bytesSoFar)
                    }
                    if legacy {
                        return mtp_send_object_from_fd(
                            s, parentHandle, primaryStorageID,
                            fileName, fileSize, format, srcFD, &newHandle,
                            cb, closurePtr
                        )
                    } else {
                        return mtp_send_object_proplist_from_fd(
                            s, parentHandle, primaryStorageID,
                            fileName, fileSize, format, srcFD, &newHandle,
                            cb, closurePtr
                        )
                    }
                }
            } else {
                if legacy {
                    return mtp_send_object_from_fd(
                        s, parentHandle, primaryStorageID,
                        fileName, fileSize, format, srcFD, &newHandle, nil, nil
                    )
                } else {
                    return mtp_send_object_proplist_from_fd(
                        s, parentHandle, primaryStorageID,
                        fileName, fileSize, format, srcFD, &newHandle, nil, nil
                    )
                }
            }
        }

        var oplSucceeded = false
        if useOPL {
            let result = runSend(/* legacy: */ false)
            if result == 0 {
                oplSucceeded = true
            } else {
                logger.warning("SendObjectPropList failed (\(self.lastError(), privacy: .public)) — retrying with legacy SendObjectInfo")
                _ = lseek(srcFD, 0, SEEK_SET)
            }
        }

        if !oplSucceeded {
            let result = runSend(/* legacy: */ true)
            guard result == 0 else {
                throw MTPError.transferFailed(file: targetPath, reason: lastError())
            }
        }

        handleCache[targetPath] = newHandle
        return fileSize
    }

    func deleteFile(at path: String) async throws {
        guard let s = session else { throw MTPError.deviceNotFound }
        let handle = try resolveFileHandle(path)
        guard mtp_delete_object(s, handle) == 0 else {
            throw MTPError.transferFailed(file: path, reason: lastError())
        }
        handleCache.removeValue(forKey: path)
    }

    func renameFile(at path: String, to newName: String) async throws {
        guard let s = session else { throw MTPError.deviceNotFound }
        let handle = try resolveFileHandle(path)
        guard mtp_rename_object(s, handle, newName) == 0 else {
            throw MTPError.transferFailed(file: path, reason: lastError())
        }
        // Update cache: remove old path, add new
        handleCache.removeValue(forKey: path)
        let parentPath = (path as NSString).deletingLastPathComponent
        let newPath = (parentPath as NSString).appendingPathComponent(newName)
        handleCache[newPath] = handle
    }

    // MARK: - Directory Creation

    /// Recursively create directories along a path, creating any missing components.
    /// Returns the handle of the deepest (leaf) directory.
    private func createDirectoryRecursive(at path: String) throws -> UInt32 {
        guard let s = session else { throw MTPError.deviceNotFound }

        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if components.isEmpty { return 0xFFFFFFFF }

        var currentParent: UInt32 = 0xFFFFFFFF
        var builtPath = ""

        for component in components {
            builtPath += "/\(component)"

            if let cached = handleCache[builtPath] {
                currentParent = cached
                continue
            }

            // Try to find existing directory
            var handles = [UInt32](repeating: 0, count: 5000)
            let count = mtp_get_object_handles(s, primaryStorageID, currentParent, 0, &handles, 5000)

            var found = false
            if count > 0 {
                var infos = [mtp_object_info_t](repeating: mtp_object_info_t(), count: Int(count))
                let infoCount = mtp_get_object_info_batch(s, &handles, &infos, count)

                for i in 0..<Int(infoCount) {
                    let name = safeString(from: infos[i].filename)
                    if name.caseInsensitiveCompare(component) == .orderedSame {
                        currentParent = infos[i].object_handle
                        handleCache[builtPath] = currentParent
                        found = true
                        break
                    }
                }
            }

            // Create if not found
            if !found {
                var newHandle: UInt32 = 0
                let result = mtp_create_folder(s, currentParent, primaryStorageID, component, &newHandle)
                guard result == 0 else {
                    throw MTPError.transferFailed(file: path, reason: "Failed to create directory: \(component)")
                }
                currentParent = newHandle
                handleCache[builtPath] = newHandle
                logger.info("Created directory: \(builtPath, privacy: .private(mask: .hash))")
            }
        }

        return currentParent
    }

    // MARK: - Device Info

    func deviceInfo() async throws -> DeviceState {
        guard let s = session else { throw MTPError.deviceNotFound }

        var storageTotal: UInt64?
        var storageFree: UInt64?

        if primaryStorageID != 0 {
            var info = mtp_storage_info_t()
            if mtp_get_storage_info(s, primaryStorageID, &info) == 0 {
                storageTotal = info.max_capacity
                storageFree = info.free_space
            }
        }

        return DeviceState(
            serialNumber: deviceSerial,
            displayName: deviceModel,
            manufacturer: deviceManufacturer,
            model: deviceModel,
            connectionStatus: .connected,
            engineType: .mtp,
            storageTotal: storageTotal,
            storageFree: storageFree
        )
    }

    func remoteChecksum(at path: String, algorithm: ChecksumAlgorithm) async throws -> String? {
        nil
    }

    // MARK: - Path Resolution (Cached)

    private func resolvePathToHandle(_ path: String) throws -> UInt32 {
        if let cached = handleCache[path] { return cached }

        guard let s = session else { throw MTPError.deviceNotFound }

        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if components.isEmpty { return 0xFFFFFFFF }

        var currentParent: UInt32 = 0xFFFFFFFF
        var builtPath = ""

        for component in components {
            builtPath += "/\(component)"

            if let cached = handleCache[builtPath] {
                currentParent = cached
                continue
            }

            var handles = [UInt32](repeating: 0, count: 5000)
            let count = mtp_get_object_handles(s, primaryStorageID, currentParent, 0, &handles, 5000)
            guard count > 0 else { throw MTPError.fileNotFound(path: path) }

            var infos = [mtp_object_info_t](repeating: mtp_object_info_t(), count: Int(count))
            let infoCount = mtp_get_object_info_batch(s, &handles, &infos, count)

            var found = false
            let parentPrefix = builtPath.count > component.count + 1
                ? String(builtPath.dropLast(component.count + 1))
                : ""

            for i in 0..<Int(infoCount) {
                let name = safeString(from: infos[i].filename)
                guard !name.isEmpty else { continue }

                // Cache ALL siblings — amortizes future lookups in the same directory
                let siblingPath = parentPrefix.isEmpty ? "/\(name)" : "\(parentPrefix)/\(name)"
                handleCache[siblingPath] = infos[i].object_handle

                if name.caseInsensitiveCompare(component) == .orderedSame {
                    currentParent = infos[i].object_handle
                    found = true
                }
            }

            if !found { throw MTPError.fileNotFound(path: path) }
        }

        return currentParent
    }

    private func resolveFileHandle(_ path: String) throws -> UInt32 {
        // Check cache first
        if let cached = handleCache[path] { return cached }

        guard let s = session else { throw MTPError.deviceNotFound }

        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else { throw MTPError.fileNotFound(path: path) }

        let fileName = components.last!
        let parentPath = components.count > 1 ? "/" + components.dropLast().joined(separator: "/") : "/"
        let parentHandle = try resolvePathToHandle(parentPath)

        // Enumerate parent directory using batch info
        var handles = [UInt32](repeating: 0, count: 10000)
        let count = mtp_get_object_handles(s, primaryStorageID, parentHandle, 0, &handles, 10000)
        guard count > 0 else { throw MTPError.fileNotFound(path: path) }

        var infos = [mtp_object_info_t](repeating: mtp_object_info_t(), count: Int(count))
        let infoCount = mtp_get_object_info_batch(s, &handles, &infos, count)

        for i in 0..<Int(infoCount) {
            let name = safeString(from: infos[i].filename)
            // Cache all entries we see (amortizes future lookups)
            let entryPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
            handleCache[entryPath] = infos[i].object_handle

            if name.caseInsensitiveCompare(fileName) == .orderedSame {
                return infos[i].object_handle
            }
        }

        throw MTPError.fileNotFound(path: path)
    }

    // MARK: - macOS USB Interface Claiming

    /// Kill the PTPCamera daemon that macOS auto-launches when an MTP/PTP device connects.
    /// Image Capture.app uses this daemon to claim the USB interface for photo import.
    /// If it's running when we try to open the MTP session, our claim fails.
    private func releasePTPCamera() async {
        // Disable ptpcamerad via launchctl so it won't respawn after being killed.
        // This is the only reliable way on macOS 26 — killall alone causes respawn.
        let uid = getuid()

        let disable = Process()
        disable.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        disable.arguments = ["disable", "gui/\(uid)/com.apple.ptpcamerad"]
        disable.standardOutput = FileHandle.nullDevice
        disable.standardError = FileHandle.nullDevice
        try? disable.run()
        disable.waitUntilExit()

        // Kill the running ptpcamerad (it won't respawn now)
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "ptpcamerad"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()

        if kill.terminationStatus == 0 {
            logger.info("Disabled and killed ptpcamerad")
            // Wait for kernel driver to release the USB interface
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Helpers

    /// Safely extract a String from a fixed-size C char tuple.
    /// Ensures null-termination by capping at the buffer size.
    private func safeString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { buf in
            let maxLen = buf.count
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // Find null terminator or use full buffer length
            var len = 0
            while len < maxLen && ptr[len] != 0 { len += 1 }
            guard len > 0 else { return "" }
            return String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8) ?? ""
        }
    }

    private func lastError() -> String {
        guard let s = session else { return "no session" }
        return safeString(from: s.pointee.last_error)
    }

    private func parseMTPDate(_ dateChars: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> Date? {
        let str = safeString(from: dateChars)
        guard str.count >= 15 else { return nil }
        return Self.mtpDateFormatter.date(from: str)
    }

    private func mtpFormatFromExtension(_ filename: String) -> UInt16 {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return UInt16(MTP_FORMAT_JPEG)
        case "png": return UInt16(MTP_FORMAT_PNG)
        case "tiff", "tif": return UInt16(MTP_FORMAT_TIFF)
        case "bmp": return UInt16(MTP_FORMAT_BMP)
        case "gif": return UInt16(MTP_FORMAT_GIF)
        case "mp4", "m4v": return UInt16(MTP_FORMAT_MP4)
        case "3gp": return UInt16(MTP_FORMAT_3GP)
        case "avi": return UInt16(MTP_FORMAT_AVI)
        case "wmv": return UInt16(MTP_FORMAT_WMV)
        case "mp3": return UInt16(MTP_FORMAT_MP3)
        case "wav": return UInt16(MTP_FORMAT_WAV)
        case "wma": return UInt16(MTP_FORMAT_WMA)
        case "aac", "m4a": return UInt16(MTP_FORMAT_AAC)
        case "flac": return UInt16(MTP_FORMAT_FLAC)
        case "dng": return UInt16(MTP_FORMAT_DNG)
        default: return UInt16(MTP_FORMAT_UNDEFINED)
        }
    }

    deinit {
        // Cleanup should be done via disconnect(). Log if it wasn't.
        if session != nil {
            let serial = deviceSerial.count > 4 ? "***\(deviceSerial.suffix(4))" : "****"
            // Cannot use instance logger in deinit — use os_log directly
            os_log(.error, log: OSLog(subsystem: "com.snaphaul.app", category: "mtp-native"),
                   "MTPNativeEngine deallocated while still connected [%{public}@]", serial)
        }
    }
}
