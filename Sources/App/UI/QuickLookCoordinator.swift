// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import AppKit
import Quartz
import os

/// Coordinates Quick Look previews for device files.
///
/// Opens the panel immediately with a placeholder, pulls the file in the
/// background, then reloads with the real content. Caches previewed files
/// (50 MB LRU) so re-previewing is instant.
@MainActor
final class QuickLookCoordinator: NSObject, ObservableObject {

    @Published var isLoading = false
    @Published var error: String?

    private(set) var previewURL: URL?
    private var panelDelegate: QuickLookPanelDelegate?
    private var cache: [String: URL] = [:]
    private let maxCacheBytes: UInt64 = 50_000_000
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

    /// Preview a remote device file. Uses cache for instant re-preview.
    func preview(
        remotePath: String,
        fileName: String,
        fileSize: UInt64,
        pullFile: @escaping (String, URL) async throws -> UInt64
    ) {
        error = nil

        // Cache hit — instant preview
        if let cachedURL = cache[remotePath],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            previewURL = cachedURL
            isLoading = false
            showPanel(url: cachedURL, title: fileName)
            promoteCacheEntry(remotePath)
            return
        }

        // Show panel immediately with placeholder
        isLoading = true
        let placeholderURL = createLoadingPlaceholder(fileName: fileName)
        showPanel(url: placeholderURL, title: "Loading \(fileName)…")

        Task {
            do {
                let tempURL = tempDir.appendingPathComponent(
                    UUID().uuidString + "_" + fileName
                )

                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }

                _ = try await pullFile(remotePath, tempURL)

                await MainActor.run {
                    self.previewURL = tempURL
                    self.isLoading = false
                    self.addToCache(remotePath: remotePath, localURL: tempURL)
                    self.showPanel(url: tempURL, title: fileName)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.error = "Preview failed: \(error.localizedDescription)"
                    if QLPreviewPanel.sharedPreviewPanelExists(),
                       let panel = QLPreviewPanel.shared(), panel.isVisible {
                        panel.close()
                    }
                }
            }
        }
    }

    /// Show or reload the Quick Look panel.
    private func showPanel(url: URL, title: String) {
        let delegate = QuickLookPanelDelegate(url: url, title: title) { [weak self] in
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

    /// Create a placeholder file so the panel has something to show while downloading.
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

    /// Clear the entire preview cache.
    func clearCache() {
        for url in cache.values {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeAll()
        cacheOrder.removeAll()
        previewURL = nil
    }

    /// Remove the current temp file from disk (non-cached).
    func cleanupTempFile() {
        if let url = previewURL, !cache.values.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        previewURL = nil
    }
}

// MARK: - QLPreviewPanel Delegate & DataSource

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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItem
    }

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        onClose()
    }
}

// MARK: - QLPreviewItem

private final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}
