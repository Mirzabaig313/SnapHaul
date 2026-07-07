// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import FileProvider
import SnapHaulKit
import UniformTypeIdentifiers
import os

/// File Provider extension — mounts the Android device as a Finder volume.
///
/// Communicates with the host app via XPC for all device I/O.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let logger = Logger(
        subsystem: "com.snaphaul.fileprovider",
        category: "extension"
    )

    let domain: NSFileProviderDomain
    private var _xpcConnection: NSXPCConnection?
    private var idleTimer: DispatchSourceTimer?
    private static let idleTimeout: TimeInterval = 60
    private let xpcQueue = DispatchQueue(label: "com.snaphaul.fileprovider.xpc")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("File Provider initialized for domain: \(domain.displayName)")
        resetIdleTimer()
    }

    // MARK: - XPC

    private var xpcConnection: NSXPCConnection? {
        if let existing = _xpcConnection { return existing }

        let connection = NSXPCConnection(
            machServiceName: "com.snaphaul.app.xpc",
            options: []
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SnapHaulXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            self?.logger.info("XPC connection invalidated")
            self?._xpcConnection = nil
        }
        connection.interruptionHandler = { [weak self] in
            self?.logger.warning("XPC connection interrupted")
            self?._xpcConnection = nil
        }
        connection.resume()
        _xpcConnection = connection
        return connection
    }

    private func hostApp() -> SnapHaulXPCProtocol? {
        resetIdleTimer()
        guard let conn = xpcConnection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("XPC proxy error: \(error.localizedDescription)")
            self?._xpcConnection = nil
        } as? SnapHaulXPCProtocol
    }

    // MARK: - Lifecycle

    func invalidate() {
        logger.info("File Provider invalidated")
        idleTimer?.cancel()
        idleTimer = nil
        _xpcConnection?.invalidate()
        _xpcConnection = nil
    }

    /// Reset the idle timer. After 60s of inactivity, the XPC connection is released.
    private func resetIdleTimer() {
        idleTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: xpcQueue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.logger.info("Idle timeout reached — releasing resources")
            self._xpcConnection?.invalidate()
            self._xpcConnection = nil
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: - Item lookup

    /// Called by macOS to get metadata for a specific item identifier.
    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        // Root container — return a synthetic root item
        if identifier == .rootContainer {
            let root = FileProviderItem(
                id: NSFileProviderItemIdentifier.rootContainer.rawValue,
                name: domain.displayName,
                parentID: "",
                isDirectory: true,
                size: 0,
                modificationDate: Date(),
                contentType: .folder
            )
            completionHandler(root, nil)
            progress.completedUnitCount = 1
            return progress
        }

        // For all other items, list the parent directory and find the matching entry
        let devicePath = identifier.rawValue
        let parentPath = (devicePath as NSString).deletingLastPathComponent
        let fileName = (devicePath as NSString).lastPathComponent

        guard let proxy = hostApp() else {
            completionHandler(nil, NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }

        proxy.listFiles(at: parentPath.isEmpty ? "/" : parentPath) { [weak self] data, error in
            guard let self else { return }

            if let error {
                self.logger.error("item lookup failed for \(devicePath): \(error.localizedDescription)")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }

            guard let data,
                  let files = try? JSONDecoder().decode([FileItem].self, from: data),
                  let match = files.first(where: { $0.name == fileName }) else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }

            let item = FileProviderItem(from: match, parentPath: parentPath)
            completionHandler(item, nil)
            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: - Android → Mac (fetch file contents)

    /// Called when the user opens or copies a file from the device volume in Finder.
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let devicePath = itemIdentifier.rawValue

        logger.info("fetchContents: \(devicePath, privacy: .private(mask: .hash))")

        guard let proxy = hostApp() else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        // Write to a temp file that macOS will move to its cache
        let fileName = (devicePath as NSString).lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaphaul-fp-\(UUID().uuidString)-\(fileName)")

        progress.completedUnitCount = 10

        proxy.pullFile(from: devicePath, to: tempURL.path) { [weak self] bytes, error in
            guard let self else { return }

            if let error {
                self.logger.error(
                    "fetchContents failed for \(devicePath, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )
                try? FileManager.default.removeItem(at: tempURL)
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            self.logger.info(
                "fetchContents complete: \(bytes) bytes for \(devicePath, privacy: .private(mask: .hash))"
            )
            progress.completedUnitCount = 100

            // Re-fetch item metadata to return alongside the content URL
            let parentPath = (devicePath as NSString).deletingLastPathComponent
            proxy.listFiles(at: parentPath.isEmpty ? "/" : parentPath) { data, _ in
                let files = data.flatMap { try? JSONDecoder().decode([FileItem].self, from: $0) }
                let fileName = (devicePath as NSString).lastPathComponent
                let match = files?.first(where: { $0.name == fileName })
                let item = match.map { FileProviderItem(from: $0, parentPath: parentPath) }
                completionHandler(tempURL, item, nil)
            }
        }

        return progress
    }

    // MARK: - Mac → Android (create / upload file)

    /// Called when the user drags a file into the device volume in Finder.
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        // Directory creation — no file content to push
        if itemTemplate.contentType == .folder {
            completionHandler(itemTemplate, [], false, nil)
            progress.completedUnitCount = 100
            return progress
        }

        guard let sourceURL = url else {
            // No content provided — this is a metadata-only create, not a file upload
            completionHandler(itemTemplate, [], false, nil)
            progress.completedUnitCount = 100
            return progress
        }

        // Build the remote path: parent identifier + filename
        let parentPath = itemTemplate.parentItemIdentifier == .rootContainer
            ? "/"
            : itemTemplate.parentItemIdentifier.rawValue
        let remotePath = parentPath == "/"
            ? "/\(itemTemplate.filename)"
            : "\(parentPath)/\(itemTemplate.filename)"

        logger.info("createItem (file): \(remotePath, privacy: .private(mask: .hash))")

        guard let proxy = hostApp() else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        progress.completedUnitCount = 10

        proxy.pushFile(from: sourceURL.path, to: remotePath) { [weak self] success, error in
            guard let self else { return }

            if let error {
                self.logger.error(
                    "createItem push failed for \(remotePath, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )
                completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                return
            }

            self.logger.info("createItem complete: \(remotePath, privacy: .private(mask: .hash))")
            progress.completedUnitCount = 100

            // Build a FileProviderItem for the newly created file
            let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            let modDate = attrs?[.modificationDate] as? Date ?? Date()
            let utType = UTType(filenameExtension: (itemTemplate.filename as NSString).pathExtension)
                ?? .data

            let createdItem = FileProviderItem(
                id: remotePath,
                name: itemTemplate.filename,
                parentID: parentPath,
                isDirectory: false,
                size: size,
                modificationDate: modDate,
                contentType: utType
            )
            completionHandler(createdItem, [], false, nil)
        }

        return progress
    }

    // MARK: - Modify (rename or overwrite existing file on device)

    /// Called by macOS when the user renames or overwrites a file in Finder.
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let currentPath = item.itemIdentifier.rawValue

        guard let proxy = hostApp() else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        let needsRename = changedFields.contains(.filename)
            && item.filename != (currentPath as NSString).lastPathComponent
        let needsContentUpdate = newContents != nil

        // Helper: build an updated FileProviderItem after rename
        func buildRenamedItem(newName: String, newPath: String) -> FileProviderItem {
            let parentPath = (newPath as NSString).deletingLastPathComponent
            let fileAttrs = try? FileManager.default.attributesOfItem(
                atPath: newContents?.path ?? ""
            )
            let size = fileAttrs?[.size] as? UInt64 ?? 0
            let modDate = fileAttrs?[.modificationDate] as? Date ?? Date()
            let utType = UTType(filenameExtension: (newName as NSString).pathExtension) ?? .data
            return FileProviderItem(
                id: newPath,
                name: newName,
                parentID: parentPath,
                isDirectory: item.contentType == .folder,
                size: size,
                modificationDate: modDate,
                contentType: utType
            )
        }

        // Helper: push content to a path, then call the completion handler
        func pushContent(to targetPath: String, resultItem: NSFileProviderItem) {
            guard let sourceURL = newContents else {
                progress.completedUnitCount = 100
                completionHandler(resultItem, [], false, nil)
                return
            }
            logger.info("modifyItem overwrite: \(targetPath, privacy: .private(mask: .hash))")
            proxy.pushFile(from: sourceURL.path, to: targetPath) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.logger.error("modifyItem overwrite failed: \(error.localizedDescription)")
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                } else {
                    progress.completedUnitCount = 100
                    completionHandler(resultItem, [], false, nil)
                }
            }
        }

        if needsRename {
            let newName = item.filename
            let directory = (currentPath as NSString).deletingLastPathComponent
            let newPath = (directory as NSString).appendingPathComponent(newName)

            logger.info("modifyItem rename: \(currentPath, privacy: .private(mask: .hash)) → \(newName, privacy: .private(mask: .hash))")

            proxy.renameFile(at: currentPath, to: newName) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.logger.error("modifyItem rename failed: \(error.localizedDescription)")
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                    return
                }
                progress.completedUnitCount = needsContentUpdate ? 50 : 100
                let renamedItem = buildRenamedItem(newName: newName, newPath: newPath)
                if needsContentUpdate {
                    pushContent(to: newPath, resultItem: renamedItem)
                } else {
                    completionHandler(renamedItem, [], false, nil)
                }
            }
        } else if needsContentUpdate {
            pushContent(to: currentPath, resultItem: item)
        } else {
            // No-op — metadata change we don't handle (e.g. tag change)
            progress.completedUnitCount = 100
            completionHandler(item, [], false, nil)
        }

        return progress
    }

    // MARK: - Delete

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let devicePath = identifier.rawValue

        logger.info("deleteItem: \(devicePath, privacy: .private(mask: .hash))")

        guard let proxy = hostApp() else {
            completionHandler(NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }

        proxy.deleteFile(at: devicePath) { [weak self] success, error in
            guard let self else { return }

            if let error {
                self.logger.error(
                    "deleteItem failed for \(devicePath, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )
                completionHandler(NSFileProviderError(.serverUnreachable))
            } else {
                self.logger.info("deleteItem complete: \(devicePath, privacy: .private(mask: .hash))")
                completionHandler(nil)
            }
            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: - Enumerator

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(
            containerIdentifier: containerItemIdentifier,
            domain: domain,
            hostApp: hostApp()
        )
    }
}
