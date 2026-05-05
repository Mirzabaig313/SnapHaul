// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SnapHaulKit

/// Full app window — file manager with sidebar, device browser, and transfer status.
struct MainWindowView: View {

    @ObservedObject var appState: AppState

    // MARK: - Sidebar state

    @State private var selectedSidebarItem: SidebarItem? = .device

    // MARK: - Device browser state

    @State private var currentPath: String = "/"
    @State private var pathStack: [String] = []
    @State private var deviceItems: [FileItem] = []
    @State private var isLoadingDevice = false
    @State private var deviceError: String?
    @State private var selectedFileIDs: Set<String> = []
    @State private var viewMode: ViewMode = .list

    // MARK: - Transfer state

    @State private var isTransferring = false
    @State private var transferMessage = ""
    @State private var transferError: String?
    @State private var transferredFiles = 0
    @State private var totalTransferFiles = 0
    @State private var transferredBytes: UInt64 = 0
    @State private var totalTransferBytes: UInt64 = 0
    @State private var transferStartTime: Date?
    @State private var showTransferPanel = true
    @State private var panelOffset: CGSize = .zero
    @State private var panelDragOffset: CGSize = .zero

    // MARK: - Quick Look

    @StateObject private var quickLookCoordinator = QuickLookCoordinator()
    @StateObject private var thumbnailCache = ThumbnailCache()

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .overlay(alignment: .bottomTrailing) {
            if isTransferring && showTransferPanel {
                transferPanel
                    .offset(
                        x: panelOffset.width + panelDragOffset.width,
                        y: panelOffset.height + panelDragOffset.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                panelDragOffset = value.translation
                            }
                            .onEnded { value in
                                panelOffset.width += value.translation.width
                                panelOffset.height += value.translation.height
                                panelDragOffset = .zero
                            }
                    )
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: isTransferring)
            }
        }
        .toolbar {
            toolbarContent
        }
        .onAppear {
            if appState.deviceState != nil {
                loadDirectory("/")
            }
        }
        .onChange(of: appState.deviceState) { _, newDevice in
            if newDevice != nil && deviceItems.isEmpty {
                loadDirectory("/")
            } else if newDevice == nil {
                deviceItems = []
                currentPath = "/"
                pathStack = []
                quickLookCoordinator.clearCache()
                thumbnailCache.clear()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSidebarItem) {
            Section("Device") {
                if let device = appState.deviceState {
                    Label(device.displayName, systemImage: "iphone.gen3")
                        .tag(SidebarItem.device)

                    // Quick-access folders
                    Label("DCIM", systemImage: "camera.fill")
                        .tag(SidebarItem.folder("/DCIM"))
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .tag(SidebarItem.folder("/Download"))
                    Label("Pictures", systemImage: "photo.on.rectangle")
                        .tag(SidebarItem.folder("/Pictures"))
                    Label("Movies", systemImage: "film")
                        .tag(SidebarItem.folder("/Movies"))
                    Label("Music", systemImage: "music.note")
                        .tag(SidebarItem.folder("/Music"))
                    Label("Documents", systemImage: "doc.fill")
                        .tag(SidebarItem.folder("/documents"))
                } else {
                    Label("No Device", systemImage: "cable.connector.slash")
                        .foregroundStyle(.secondary)
                }
            }

            if !appState.profiles.isEmpty {
                Section("Ingest Profiles") {
                    ForEach(appState.profiles) { profile in
                        Label(profile.name, systemImage: "tray.and.arrow.down")
                            .tag(SidebarItem.profile(profile.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
        .onChange(of: selectedSidebarItem) { _, newItem in
            handleSidebarSelection(newItem)
        }
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detailContent: some View {
        if appState.deviceState == nil {
            ContentUnavailableView(
                "No Device Connected",
                systemImage: "cable.connector.slash",
                description: Text("Connect an Android device via USB and set it to File Transfer mode.")
            )
        } else if let error = deviceError {
            ContentUnavailableView(
                "Error",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            VStack(spacing: 0) {
                pathBar
                Divider()
                fileListView
                Divider()
                statusBar
            }
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                if let prev = pathStack.popLast() {
                    currentPath = prev
                    selectedFileIDs = []
                    loadDirectory(prev)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(pathStack.isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(breadcrumbs, id: \.path) { crumb in
                        Button {
                            navigateTo(crumb.path)
                        } label: {
                            Text(crumb.label)
                                .font(.callout)
                                .foregroundStyle(crumb.path == currentPath ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)

                        if crumb.path != currentPath {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }

            Spacer()

            if !isLoadingDevice {
                Text("\(deviceItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - File list

    @ViewBuilder
    private var fileListView: some View {
        if isLoadingDevice {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if deviceItems.isEmpty {
            ContentUnavailableView(
                "Empty Folder",
                systemImage: "folder",
                description: Text(currentPath)
            )
        } else {
            switch viewMode {
            case .list:
                VStack(spacing: 0) {
                    fileListHeader
                    Divider()
                    fileListBody
                }
            case .icons:
                iconGridBody
            }
        }
    }

    /// Column headers for the list view.
    private var fileListHeader: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 30)
            Text("Name")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text("Modified")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text("Type")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// File list with drag-drop and context menu support.
    private var fileListBody: some View {
        List(selection: $selectedFileIDs) {
            ForEach(deviceItems) { item in
                fileRow(item)
                    .tag(item.id)
            }
        }
        .listStyle(.plain)
        .alternatingRowBackgrounds(.enabled)
        .onDrop(of: [.fileURL, .url], isTargeted: nil) { providers in
            let hasFileURLs = providers.contains { $0.canLoadObject(ofClass: URL.self) }
            if hasFileURLs {
                handleDropFromFinder(providers)
            }
            return hasFileURLs
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = deviceItems.first(where: { $0.id == id }) {
                if item.isDirectory {
                    Button("Open Folder") { navigateInto(item) }
                }
                if !item.isDirectory {
                    Button("Quick Look") { quickLookFile(item) }
                }
            }
            Button("Copy to Mac…") { copySelectedToMac() }
                .disabled(selectedFileIDs.isEmpty)
        } primaryAction: { ids in
            if let id = ids.first, let item = deviceItems.first(where: { $0.id == id }), item.isDirectory {
                navigateInto(item)
            }
        }
        .onKeyPress(.space) {
            quickLookSelectedFile()
            return .handled
        }
    }

    /// A single file/folder row matching the header columns.
    private func fileRow(_ item: FileItem) -> some View {
        HStack(spacing: 0) {
            Image(systemName: iconName(for: item))
                .foregroundStyle(item.isDirectory ? .yellow : .secondary)
                .frame(width: 30)

            Text(item.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.isDirectory {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text(ByteFormatter.format(item.size))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }

            Text(item.modificationDate, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            Text(item.isDirectory ? "Folder" : fileExtension(item.name))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Icon Grid View

    /// Grid view showing file thumbnails — like Finder's icon view.
    private var iconGridBody: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)],
                spacing: 12
            ) {
                ForEach(deviceItems) { item in
                    iconGridItem(item)
                        .onTapGesture {
                            if selectedFileIDs.contains(item.id) {
                                selectedFileIDs.remove(item.id)
                            } else {
                                selectedFileIDs = [item.id]
                            }
                        }
                        .onTapGesture(count: 2) {
                            if item.isDirectory {
                                navigateInto(item)
                            } else {
                                quickLookFile(item)
                            }
                        }
                }
            }
            .padding(16)
        }
        .onKeyPress(.space) {
            quickLookSelectedFile()
            return .handled
        }
        .contextMenu {
            Button("Copy to Mac…") { copySelectedToMac() }
                .disabled(selectedFileIDs.isEmpty)
        }
    }

    /// A single item in the icon grid — thumbnail + filename.
    private func iconGridItem(_ item: FileItem) -> some View {
        let isSelected = selectedFileIDs.contains(item.id)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .frame(width: 88, height: 88)

                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.yellow)
                } else if isImageFile(item.name) {
                    ThumbnailView(
                        item: item,
                        appState: appState,
                        cache: thumbnailCache
                    )
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: iconName(for: item))
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)

            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 96)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    /// Whether a filename is a previewable image type.
    private func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff", "gif"].contains(ext)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isTransferring {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(transferredFiles)/\(totalTransferFiles) files · \(currentSpeed)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if !showTransferPanel {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showTransferPanel = true
                                panelOffset = .zero
                            }
                        } label: {
                            Text("Show Details")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            } else if quickLookCoordinator.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let qlError = quickLookCoordinator.error {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(qlError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("Dismiss") { quickLookCoordinator.error = nil }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if let error = transferError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("Dismiss") { transferError = nil }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if selectedFileIDs.isEmpty {
                Text("\(deviceItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let selected = deviceItems.filter { selectedFileIDs.contains($0.id) }
                let totalBytes = selected.reduce(UInt64(0)) { $0 + $1.size }
                Text("\(selected.count) selected · \(ByteFormatter.format(totalBytes))")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Spacer()

            if appState.deviceState != nil && !isTransferring {
                Button {
                    sendToDevice()
                } label: {
                    Label("Send to Device", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !selectedFileIDs.isEmpty {
                    Button {
                        copySelectedToMac()
                    } label: {
                        Label("Copy to Mac", systemImage: "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Floating transfer progress panel.
    private var transferPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.doc.fill")
                    .foregroundColor(.accentColor)
                Text("Transferring Files")
                    .font(.headline)
                Spacer()
                Text("\(Int(transferProgress * 100))%")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTransferPanel = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Hide panel (transfer continues)")
            }

            ProgressView(value: transferProgress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(transferredFiles) / \(totalTransferFiles)")
                        .font(.callout)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Transferred")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(ByteFormatter.format(transferredBytes)) / \(ByteFormatter.format(totalTransferBytes))")
                        .font(.callout)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(currentSpeed)
                        .font(.callout)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(estimatedTimeRemaining ?? "Calculating…")
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    /// Transfer progress as a fraction 0.0–1.0.
    private var transferProgress: Double {
        guard totalTransferBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalTransferBytes)
    }

    /// Current transfer speed formatted as "XX.X MB/s".
    private var currentSpeed: String {
        guard let start = transferStartTime else { return "—" }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.5 else { return "—" }
        let bytesPerSec = Double(transferredBytes) / elapsed
        let mbps = bytesPerSec / 1_000_000
        return String(format: "%.1f MB/s", mbps)
    }

    /// Estimated time remaining formatted as "Xm Xs" or "Xs".
    private var estimatedTimeRemaining: String? {
        guard let start = transferStartTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 1, transferredBytes > 0 else { return nil }
        let bytesPerSec = Double(transferredBytes) / elapsed
        guard bytesPerSec > 0 else { return nil }
        let remainingBytes = Double(totalTransferBytes) - Double(transferredBytes)
        let remainingSecs = Int(remainingBytes / bytesPerSec)
        if remainingSecs > 60 {
            return "\(remainingSecs / 60)m \(remainingSecs % 60)s"
        }
        return "\(remainingSecs)s"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let device = appState.deviceState {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(device.displayName)
                        .font(.headline)
                }
            }
        }

        ToolbarItem {
            Button {
                loadDirectory(currentPath)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(isLoadingDevice)
        }

        ToolbarItem {
            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet")
                    .tag(ViewMode.list)
                Image(systemName: "square.grid.2x2")
                    .tag(ViewMode.icons)
            }
            .pickerStyle(.segmented)
            .help("Switch between list and icon view")
        }

        ToolbarItem {
            if let progress = appState.transferProgress {
                HStack(spacing: 6) {
                    ProgressView(value: progress.overallProgress)
                        .frame(width: 100)
                    Text("\(progress.completedFiles)/\(progress.totalFiles)")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Drag & Drop

    private func handleDropFromFinder(_ providers: [NSItemProvider]) {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !urlProviders.isEmpty else { return }

        var fileURLs: [URL] = []
        let group = DispatchGroup()

        for provider in urlProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url, url.isFileURL {
                    fileURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            guard !fileURLs.isEmpty else { return }
            self.pushFilesToDevice(fileURLs)
        }
    }

    /// Push local Mac files to the current device directory.
    private func pushFilesToDevice(_ urls: [URL]) {
        // Calculate total size
        var totalSize: UInt64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        isTransferring = true
        transferError = nil
        transferredFiles = 0
        totalTransferFiles = urls.count
        transferredBytes = 0
        totalTransferBytes = totalSize
        transferStartTime = Date()
        showTransferPanel = true
        panelOffset = .zero

        let refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let current = self.transferredBytes
                self.transferredBytes = current
            }
        }

        Task {
            do {
                var completedBytes: UInt64 = 0
                for url in urls {
                    let remotePath = currentPath.hasSuffix("/")
                        ? "\(currentPath)\(url.lastPathComponent)"
                        : "\(currentPath)/\(url.lastPathComponent)"
                    try await appState.pushFile(from: url, to: remotePath)
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
                    completedBytes += fileSize
                    await MainActor.run {
                        transferredFiles += 1
                        transferredBytes = completedBytes
                    }
                }
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    loadDirectory(currentPath)
                }
            } catch {
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    transferError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Actions

    // MARK: Quick Look

    /// Preview the first selected non-directory file via Quick Look.
    private func quickLookSelectedFile() {
        guard let id = selectedFileIDs.first,
              let item = deviceItems.first(where: { $0.id == id }),
              !item.isDirectory else {
            return
        }
        quickLookFile(item)
    }

    /// Pull a file to a temp location and open it in Quick Look.
    private func quickLookFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        quickLookCoordinator.preview(
            remotePath: item.path,
            fileName: item.name,
            fileSize: item.size
        ) { [appState] remotePath, localURL in
            try await appState.pullFile(from: remotePath, to: localURL)
        }
    }

    private func copySelectedToMac() {
        let selected = deviceItems.filter { selectedFileIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to save \(selected.count) file(s)"

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isTransferring = true
        transferError = nil
        transferredFiles = 0
        totalTransferFiles = selected.count
        transferredBytes = 0
        totalTransferBytes = selected.reduce(UInt64(0)) { $0 + $1.size }
        transferStartTime = Date()
        showTransferPanel = true
        panelOffset = .zero

        let refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let current = self.transferredBytes
                self.transferredBytes = current
            }
        }

        var completedBytesBeforeCurrentFile: UInt64 = 0

        Task {
            do {
                for file in selected {
                    let localURL = destURL.appendingPathComponent(file.name)
                    let baseBytes = completedBytesBeforeCurrentFile

                    let bytes = try await appState.pullFile(
                        from: file.path,
                        to: localURL
                    ) { bytesWrittenSoFar in
                        Task { @MainActor in
                            self.transferredBytes = baseBytes + bytesWrittenSoFar
                        }
                    }

                    completedBytesBeforeCurrentFile += bytes
                    await MainActor.run {
                        transferredFiles += 1
                        transferredBytes = completedBytesBeforeCurrentFile
                    }
                }
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    selectedFileIDs = []
                    NSWorkspace.shared.open(destURL)
                }
            } catch {
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    transferError = error.localizedDescription
                }
            }
        }
    }

    private func sendToDevice() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Device"
        panel.message = "Choose files to send to \(currentPath)"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        var totalSize: UInt64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        isTransferring = true
        transferError = nil
        transferredFiles = 0
        totalTransferFiles = urls.count
        transferredBytes = 0
        totalTransferBytes = totalSize
        transferStartTime = Date()
        showTransferPanel = true
        panelOffset = .zero

        let refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let current = self.transferredBytes
                self.transferredBytes = current
            }
        }

        Task {
            do {
                for url in urls {
                    let remotePath = currentPath.hasSuffix("/")
                        ? "\(currentPath)\(url.lastPathComponent)"
                        : "\(currentPath)/\(url.lastPathComponent)"
                    try await appState.pushFile(from: url, to: remotePath)
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
                    await MainActor.run {
                        transferredFiles += 1
                        transferredBytes += fileSize
                    }
                }
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    loadDirectory(currentPath)
                }
            } catch {
                await MainActor.run {
                    refreshTimer.invalidate()
                    isTransferring = false
                    transferError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Navigation

    private func navigateInto(_ item: FileItem) {
        pathStack.append(currentPath)
        currentPath = item.path
        selectedFileIDs = []
        loadDirectory(item.path)
    }

    private func navigateTo(_ path: String) {
        guard path != currentPath else { return }
        pathStack.append(currentPath)
        currentPath = path
        selectedFileIDs = []
        loadDirectory(path)
    }

    private func handleSidebarSelection(_ item: SidebarItem?) {
        guard let item else { return }
        switch item {
        case .device:
            currentPath = "/"
            pathStack = []
            selectedFileIDs = []
            loadDirectory("/")
        case .folder(let path):
            currentPath = path
            pathStack = ["/"]
            selectedFileIDs = []
            loadDirectory(path)
        case .profile(let id):
            if let profile = appState.profiles.first(where: { $0.id == id }) {
                appState.startIngest(profile: profile)
            }
        }
    }

    private func loadDirectory(_ path: String) {
        isLoadingDevice = true
        deviceError = nil
        thumbnailCache.clear()

        Task {
            do {
                let files = try await appState.listDeviceFiles(at: path)
                await MainActor.run {
                    deviceItems = files
                        .filter { !$0.name.hasPrefix(".") }
                        .sorted {
                            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                    isLoadingDevice = false
                }
            } catch {
                await MainActor.run {
                    deviceError = error.localizedDescription
                    isLoadingDevice = false
                }
            }
        }
    }

    // MARK: - Helpers

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

    private func iconName(for item: FileItem) -> String {
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
        default:
            return "doc"
        }
    }

    private func fileExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "—" : ext
    }
}

// MARK: - Double-click modifier for Table

extension View {
    /// Adds a double-click handler. Used on Table rows.
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        self.gesture(
            TapGesture(count: 2).onEnded { action() }
        )
    }
}

// MARK: - Sidebar items

enum SidebarItem: Hashable {
    case device
    case folder(String)
    case profile(UUID)
}

// MARK: - View Mode

enum ViewMode: String {
    case list
    case icons
}

// MARK: - Thumbnail Cache

/// Caches downloaded thumbnail images for the icon grid view.
/// Downloads lazily on scroll, LRU eviction at 200 entries.
@MainActor
final class ThumbnailCache: ObservableObject {

    @Published var thumbnails: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let maxEntries = 200
    private let maxConcurrentLoads = 3
    private var order: [String] = []
    private var pendingQueue: [FileItem] = []
    private weak var currentAppState: AppState?

    /// Load a thumbnail if not already cached or in-flight.
    func loadThumbnail(for item: FileItem, using appState: AppState) {
        if thumbnails[item.path] != nil { return }
        guard !inFlight.contains(item.path) else { return }

        currentAppState = appState

        if inFlight.count >= maxConcurrentLoads {
            if !pendingQueue.contains(where: { $0.path == item.path }) {
                pendingQueue.append(item)
            }
            return
        }

        startLoad(item, using: appState)
    }

    private func startLoad(_ item: FileItem, using appState: AppState) {
        inFlight.insert(item.path)

        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("com.snaphaul.thumbnails", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + item.name)
                _ = try await appState.pullFile(from: item.path, to: tempURL)

                if let image = NSImage(contentsOf: tempURL) {
                    let thumb = image.resized(to: NSSize(width: 160, height: 160))
                    self.thumbnails[item.path] = thumb
                    self.order.append(item.path)
                    self.evictIfNeeded()
                }
                self.inFlight.remove(item.path)
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                self.inFlight.remove(item.path)
            }

            self.processNextPending()
        }
    }

    private func processNextPending() {
        guard inFlight.count < maxConcurrentLoads,
              !pendingQueue.isEmpty,
              let appState = currentAppState else { return }

        let next = pendingQueue.removeFirst()
        if thumbnails[next.path] == nil && !inFlight.contains(next.path) {
            startLoad(next, using: appState)
        } else {
            processNextPending()
        }
    }

    /// Clear all cached thumbnails.
    func clear() {
        thumbnails.removeAll()
        order.removeAll()
        inFlight.removeAll()
        pendingQueue.removeAll()
    }

    private func evictIfNeeded() {
        while thumbnails.count > maxEntries, !order.isEmpty {
            let oldest = order.removeFirst()
            thumbnails.removeValue(forKey: oldest)
        }
    }
}

// MARK: - Thumbnail View

/// Displays a thumbnail for a device image file.
/// Observes the cache and triggers loading on appear.
struct ThumbnailView: View {
    let item: FileItem
    let appState: AppState
    @ObservedObject var cache: ThumbnailCache

    var body: some View {
        Group {
            if let image = cache.thumbnails[item.path] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            cache.loadThumbnail(for: item, using: appState)
        }
    }
}

// MARK: - NSImage Resize Helper

extension NSImage {
    /// Resize the image to fit within the given size, maintaining aspect ratio.
    func resized(to targetSize: NSSize) -> NSImage {
        let ratioW = targetSize.width / size.width
        let ratioH = targetSize.height / size.height
        let ratio = min(ratioW, ratioH)

        let newSize = NSSize(
            width: size.width * ratio,
            height: size.height * ratio
        )

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}

