// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import FileProvider
import SnapHaulKit
import os

/// Enumerates files and folders on the Android device for Finder.
///
/// macOS calls this when the user opens a folder in the device volume.
/// We ask the host app via XPC for the directory listing, convert each
/// FileItem to a FileProviderItem, and hand them to the observer.
///
/// MTP has no push-based change notifications, so enumerateChanges
/// always reports no changes. The user can force a refresh with ⌘R in Finder.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let logger = Logger(
        subsystem: "com.snaphaul.fileprovider",
        category: "enumerator"
    )

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain
    private let proxy: SnapHaulXPCProtocol?

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        domain: NSFileProviderDomain,
        hostApp: SnapHaulXPCProtocol?
    ) {
        self.containerIdentifier = containerIdentifier
        self.domain = domain
        self.proxy = hostApp
        super.init()
    }

    func invalidate() {}

    // MARK: - Enumerate items (directory listing)

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // Determine the device path to list
        let devicePath: String
        if containerIdentifier == .rootContainer {
            devicePath = "/"
        } else {
            devicePath = containerIdentifier.rawValue
        }

        logger.debug("enumerateItems at: \(devicePath, privacy: .private(mask: .hash))")

        guard let proxy else {
            // Host app not running — show empty volume rather than an error
            logger.warning("No XPC proxy — host app may not be running")
            observer.finishEnumerating(upTo: nil)
            return
        }

        proxy.listFiles(at: devicePath) { [weak self] data, error in
            guard let self else { return }

            if let error {
                self.logger.error(
                    "enumerateItems failed at \(devicePath, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )
                // Report server unreachable so Finder shows a meaningful error
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }

            guard let data,
                  let files = try? JSONDecoder().decode([FileItem].self, from: data) else {
                self.logger.error("Failed to decode file listing from XPC")
                observer.finishEnumerating(upTo: nil)
                return
            }

            // Convert FileItem → FileProviderItem
            let items: [FileProviderItem] = files.map { file in
                FileProviderItem(from: file, parentPath: devicePath)
            }

            self.logger.debug(
                "enumerateItems: \(items.count) items at \(devicePath, privacy: .private(mask: .hash))"
            )

            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    // MARK: - Enumerate changes

    /// MTP devices have no push-based change notifications.
    /// We report no changes — Finder's manual refresh (⌘R) re-enumerates.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        // Timestamp-based anchor — MTP has no native versioning
        let anchor = NSFileProviderSyncAnchor(
            "\(Date().timeIntervalSince1970)".data(using: .utf8)!
        )
        completionHandler(anchor)
    }
}
