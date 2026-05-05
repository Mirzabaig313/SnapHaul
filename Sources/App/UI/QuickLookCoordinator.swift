// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import AppKit
import Quartz
import os

/// Coordinates Quick Look previews for device files.
///
/// When the user presses spacebar on a selected file, this coordinator:
/// 1. Opens the Quick Look panel immediately with a loading placeholder
/// 2. Pulls the file from the device to a temp directory in the background
/// 3. Reloads the panel with the real file once the download completes
///
/// Includes a file cache so re-previewing the same file is instant.
@MainActor
final class QuickLookCoordinator: NSObject, ObservableObject {

    @Published var isLoading = false
    @Published var error: String?

    /// The currently previewed temp file URL.
    private(set) var previewURL: URL?

    /// Delegate object that bridges QLPreviewPanel to this coordinator.
    private var panelDelegate: QuickLookPanelDelegate?

    /// Cache of already-downloaded preview files: remotePath → local temp URL.
    /// Avoids re-downloading when the user presses spacebar on the same file again.
    private var cache: [String: URL] = [:]

    /// Maximum cache size in bytes (50 MB). Oldest entries evicted on overflow.
    private let maxCacheBytes: UInt64 = 50_000_000

    /// Ordered list of cached paths for LRU eviction.
    private var cacheOrder: [String] = []

    private let logger = Logger(
        subsystem: "com.snaphaul.app",
        category: "quicklook"
    )

    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.snaphaul.quicklook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Preview a remote device file.
    ///
    /// If the file is already cached, opens Quick Look instantly.
    /// Otherwise shows the panel immediately (with a loading title) and
    /// swaps in the real content once the pull completes.
    func preview(
        remotePath: String,
        fileName: String,
        fileSize: UInt64,
        pullFile: @escaping (String, URL) async throws -> UInt64
    ) {
        error = nil

        // Check cache first — instant preview
        if let cachedURL = cache[remotePath],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            logger.debug("Quick Look cache hit: \(fileName)")
            previewURL = cachedURL
            isLoading = false
            showPanel(url: cachedURL, title: fileName)
            promoteCacheEntry(remotePath)
            return
        }

        // Show panel immediately with a "loading" state
        isLoading = true
        let placeholderURL = createLoadingPlaceholder(fileName: fileName)
        showPanel(url: placeholderURL, title: "Loading \(fileName)…")

        Task {
            do {
                let tempURL = tempDir.appendingPathComponent(
                    UUID().uuidString + "_" + fileName
                )

                // Remove stale file if it exists
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }

                logger.debug("Quick Look: pulling \(fileName) (\(fileSize) bytes)")
                _ = try await pullFile(remotePath, tempURL)

                await MainActor.run {
                    self.previewURL = tempURL
                    self.isLoading = false

                    // Add to cache
                    self.addToCache(remotePath: remotePath, localURL: tempURL)

                    // Reload the panel with the real file
                    self.showPanel(url: tempURL, title: fileName)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.error = "Preview failed: \(error.localizedDescription)"
                    self.logger.error("Quick Look pull failed: \(error.localizedDescription)")
                    // Close the panel since we can't show anything useful
                    if QLPreviewPanel.sharedPreviewPanelExists(),
                       let panel = QLPreviewPanel.shared(), panel.isVisible {
                        panel.close()
                    }
                }
            }
        }
    }

    /// Show or reload the Quick Look panel with the given URL.
    private func showPanel(url: URL, title: String) {
        let delegate = QuickLookPanelDelegate(url: url, title: title) { [weak self] in
            // Don't clean up cached files on close — keep them for re-preview
            self?.previewURL = nil
        }
        self.panelDelegate = delegate

        let panel = QLPreviewPanel.shared()!
        panel.dataSource = delegate
        panel.delegate = delegate

        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Create a tiny placeholder text file so the panel has something to show
    /// while the real file downloads.
    private func createLoadingPlaceholder(fileName: String) -> URL {
        let placeholderURL = tempDir.appendingPathComponent("_loading_\(fileName).txt")
        let message = "Downloading \(fileName) from device…"
        try? message.write(to: placeholderURL, atomically: true, encoding: .utf8)
        return placeholderURL
    }

    // MARK: - Cache Management

    private func addToCache(remotePath: String, localURL: URL) {
        cache[remotePath] = localURL
        cacheOrder.append(remotePath)
        evictIfNeeded()
    }

    private func promoteCacheEntry(_ remotePath: String) {
        cacheOrder.removeAll { $0 == remotePath }
        cacheOrder.append(remotePath)
    }

    private func evictIfNeeded() {
        var totalSize: UInt64 = 0
        for url in cache.values {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        // Evict oldest entries until under budget
        while totalSize > maxCacheBytes, !cacheOrder.isEmpty {
            let oldest = cacheOrder.removeFirst()
            if let url = cache.removeValue(forKey: oldest) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    totalSize -= size
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Clear the entire preview cache (e.g., on device disconnect).
    func clearCache() {
        for url in cache.values {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeAll()
        cacheOrder.removeAll()
        previewURL = nil
    }

    /// Remove the current temp file from disk (non-cached cleanup).
    func cleanupTempFile() {
        if let url = previewURL, !cache.values.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        previewURL = nil
    }
}

// MARK: - QLPreviewPanel Delegate & DataSource

/// Bridges `QLPreviewPanel` to a single file URL.
private final class QuickLookPanelDelegate: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private let url: URL
    private let title: String
    private let onClose: () -> Void
    private let previewItem: QuickLookItem

    init(url: URL, title: String, onClose: @escaping () -> Void) {
        self.url = url
        self.title = title
        self.onClose = onClose
        self.previewItem = QuickLookItem(url: url, title: title)
        super.init()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItem
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        onClose()
    }
}

// MARK: - QLPreviewItem

/// A `QLPreviewItem` wrapping a file URL with a custom title.
private final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}
