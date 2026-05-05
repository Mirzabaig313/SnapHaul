// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import AppKit
import SnapHaulKit

/// Full file browser for the connected Android device.
///
/// - Browse any folder on the device (starts at root /)
/// - Select individual files or folders (any extension)
/// - Copy selected items: Device → Mac or Mac → Device
struct DeviceBrowserView: View {

    @ObservedObject var appState: AppState

    // MARK: - Navigation State

    @State private var currentPath: String = "/"
    @State private var pathStack: [String] = []
    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    // MARK: - Selection State

    @State private var selectedIDs: Set<String> = []

    // MARK: - Transfer State

    @State private var isTransferring = false
    @State private var transferMessage: String = ""
    @State private var transferError: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { loadDirectory("/") }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Back
            Button {
                guard let prev = pathStack.popLast() else { return }
                currentPath = prev
                selectedIDs = []
                loadDirectory(prev)
            } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(pathStack.isEmpty)

            // Path breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(breadcrumbs, id: \.path) { crumb in
                        Button {
                            navigateTo(crumb.path)
                        } label: {
                            Text(crumb.label)
                                .font(.caption)
                                .foregroundStyle(crumb.path == currentPath ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)

                        if crumb.path != currentPath {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            // Select all / deselect all
            if !items.isEmpty {
                Button(selectedIDs.count == items.count ? "Deselect All" : "Select All") {
                    if selectedIDs.count == items.count {
                        selectedIDs = []
                    } else {
                        selectedIDs = Set(items.map(\.id))
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Refresh
            Button {
                loadDirectory(currentPath)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh directory listing")
            .disabled(isLoading)

            // Close
            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView("Loading \(currentPath)…")
                .frame(maxWidth: .infinity)
            Spacer()
        } else if let error = errorMessage {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { loadDirectory(currentPath) }
                    .buttonStyle(.bordered)
            }
            Spacer()
        } else if items.isEmpty {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Empty folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List(items) { item in
            HStack(spacing: 10) {
                // Checkbox — only for files, not folders
                if !item.isDirectory {
                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary.opacity(0.4))
                        .font(.body)
                } else {
                    Image(systemName: fileIcon(for: item))
                        .foregroundStyle(.yellow)
                        .frame(width: 18)
                }

                // Icon for files (folders already have their icon above)
                if !item.isDirectory {
                    Image(systemName: fileIcon(for: item))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }

                // Name + size
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                    if !item.isDirectory {
                        Text(ByteFormatter.format(item.size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Chevron for folders
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.isDirectory {
                    navigateInto(item)
                } else {
                    toggleSelection(item)
                }
            }
        }
        .listStyle(.plain)
    }

    /// Navigate into a folder on the device.
    private func navigateInto(_ item: FileItem) {
        pathStack.append(currentPath)
        currentPath = item.path
        selectedIDs = []
        loadDirectory(item.path)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Selection summary
            VStack(alignment: .leading, spacing: 2) {
                if isTransferring {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(transferMessage)
                            .font(.caption)
                    }
                } else if let error = transferError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Button {
                            transferError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                } else if selectedIDs.isEmpty {
                    Text("Tap files to select, then copy")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    let count = selectedIDs.count
                    let totalBytes = selectedItems.reduce(UInt64(0)) { $0 + $1.size }
                    Text("\(count) item\(count == 1 ? "" : "s") selected · \(ByteFormatter.format(totalBytes))")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }

            Spacer()

            if !isTransferring {
                // Mac → Device (always available — doesn't need device file selection)
                Button {
                    sendToDevice()
                } label: {
                    Label("Send to Device", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Device → Mac (only when device files are selected)
                if !selectedIDs.isEmpty {
                    Button {
                        copyToMac()
                    } label: {
                        Label("Copy to Mac", systemImage: "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func toggleSelection(_ item: FileItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// Copy selected device files to a user-chosen Mac folder.
    private func copyToMac() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to save the selected files on your Mac"

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isTransferring = true
        transferMessage = "Copying \(selectedIDs.count) item(s)…"

        let filesToCopy = selectedItems

        Task {
            do {
                var copied = 0
                for file in filesToCopy {
                    let localURL = destURL.appendingPathComponent(file.name)
                    _ = try await appState.pullFile(from: file.path, to: localURL)
                    copied += 1
                    await MainActor.run {
                        transferMessage = "Copied \(copied) / \(filesToCopy.count)…"
                    }
                }
                await MainActor.run {
                    isTransferring = false
                    selectedIDs = []
                    // Open the destination in Finder
                    NSWorkspace.shared.open(destURL)
                }
            } catch {
                await MainActor.run {
                    isTransferring = false
                    transferError = error.localizedDescription
                }
            }
        }
    }

    /// Send Mac files to the current device folder.
    private func sendToDevice() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Device"
        panel.message = "Choose files to send to \(currentPath) on your device"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        isTransferring = true
        transferMessage = "Sending \(urls.count) file(s)…"

        Task {
            do {
                var sent = 0
                for url in urls {
                    let remotePath = currentPath.hasSuffix("/")
                        ? "\(currentPath)\(url.lastPathComponent)"
                        : "\(currentPath)/\(url.lastPathComponent)"
                    // Use URL-based push to avoid loading the entire file into memory.
                    try await appState.pushFile(from: url, to: remotePath)
                    sent += 1
                    await MainActor.run {
                        transferMessage = "Sent \(sent) / \(urls.count)…"
                    }
                }
                await MainActor.run {
                    isTransferring = false
                    selectedIDs = []
                    loadDirectory(currentPath)
                }
            } catch {
                await MainActor.run {
                    isTransferring = false
                    transferError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Directory Loading

    private func loadDirectory(_ path: String) {
        isLoading = true
        errorMessage = nil
        items = []

        Task {
            do {
                let files = try await appState.listDeviceFiles(at: path)
                await MainActor.run {
                    self.items = files
                        .filter { !$0.name.hasPrefix(".") }
                        .sorted {
                            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func navigateTo(_ path: String) {
        guard path != currentPath else { return }
        pathStack.append(currentPath)
        currentPath = path
        selectedIDs = []
        loadDirectory(path)
    }

    // MARK: - Computed

    private var selectedItems: [FileItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    /// Build breadcrumb components from the current path.
    private var breadcrumbs: [(label: String, path: String)] {
        var crumbs: [(label: String, path: String)] = [("Device", "/")]
        let components = currentPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        var built = ""
        for component in components {
            built += "/\(component)"
            crumbs.append((label: component, path: built))
        }
        return crumbs
    }

    // MARK: - Icons

    private func fileIcon(for item: FileItem) -> String {
        if item.isDirectory { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff":
            return "photo"
        case "dng", "arw", "cr3", "nef", "raf", "rw2", "orf":
            return "camera.aperture"
        case "mp4", "mov", "avi", "mkv", "wmv", "m4v":
            return "video"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "apk":
            return "app.badge"
        case "txt", "md", "log":
            return "doc.text"
        case "xml", "json", "csv":
            return "doc.badge.gearshape"
        default:
            return "doc"
        }
    }
}
