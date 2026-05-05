// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import SwiftUI
import SnapHaulKit

/// Main preferences window with tabbed navigation.
struct PreferencesView: View {

    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            DevicesTab(appState: appState)
                .tabItem {
                    Label("Devices", systemImage: "iphone.gen3")
                }

            IngestProfilesTab(appState: appState)
                .tabItem {
                    Label("Ingest Profiles", systemImage: "tray.and.arrow.down")
                }

            TransferHistoryTab()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(width: 680, height: 480)
    }
}

// MARK: - Tab Placeholders

/// Devices tab — shows the currently connected device and engine preference.
private struct DevicesTab: View {
    @ObservedObject var appState: AppState
    @AppStorage("preferredEngine") private var preferredEngine = "auto"

    var body: some View {
        VStack(spacing: 0) {
            if let device = appState.deviceState {
                connectedDeviceView(device)
            } else {
                ContentUnavailableView(
                    "No Device Connected",
                    systemImage: "cable.connector.slash",
                    description: Text("Connect an Android device via USB to get started.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectedDeviceView(_ device: DeviceState) -> some View {
        Form {
            Section("Connected Device") {
                LabeledContent("Name", value: device.displayName)
                LabeledContent("Manufacturer", value: device.manufacturer)
                LabeledContent("Serial", value: device.redactedSerial)
                if let speed = device.usbSpeedDescription {
                    LabeledContent("USB Speed", value: speed)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text(device.connectionStatus.rawValue.capitalized)
                    }
                }
                if let engine = device.engineType {
                    LabeledContent("Engine", value: engine.rawValue.uppercased())
                }
                if let total = device.storageTotal, let free = device.storageFree {
                    LabeledContent("Storage") {
                        let totalGB = Double(total) / 1_073_741_824
                        let freeGB = Double(free) / 1_073_741_824
                        Text(String(format: "%.1f GB free / %.1f GB total", freeGB, totalGB))
                    }
                }
            }

            Section("Engine Preference for This Device") {
                Picker("Transfer engine", selection: $preferredEngine) {
                    Text("Auto (recommended)").tag("auto")
                    Text("MTP — File Transfer mode").tag("mtp")
                    Text("ADB — USB Debugging mode").tag("adb")
                }
                .pickerStyle(.radioGroup)
                Text("ADB is faster for large batches but requires USB Debugging to be enabled on the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ingest Profiles Tab

/// Ingest profiles tab — create, edit, delete profiles.
private struct IngestProfilesTab: View {
    @ObservedObject var appState: AppState
    @State private var selectedProfileID: UUID?

    var body: some View {
        NavigationSplitView {
            profileList
        } detail: {
            profileDetail
        }
    }

    @ViewBuilder
    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedProfileID) {
                ForEach(appState.profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.headline)
                        Text(profile.destinationPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(profile.id)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a new ingest profile")

                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedProfileID == nil)
                .help("Delete the selected profile")

                Spacer()
            }
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let id = selectedProfileID,
           let index = appState.profiles.firstIndex(where: { $0.id == id }) {
            ProfileEditorView(profile: $appState.profiles[index]) {
                appState.saveProfiles()
            }
        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "tray.and.arrow.down",
                description: Text("Select a profile from the sidebar or create a new one.")
            )
        }
    }

    private func addProfile() {
        let newProfile = IngestProfile(
            name: "New Profile",
            destinationPath: NSHomeDirectory() + "/Pictures/SnapHaul"
        )
        appState.profiles.append(newProfile)
        selectedProfileID = newProfile.id
        appState.saveProfiles()
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        appState.profiles.removeAll { $0.id == id }
        selectedProfileID = appState.profiles.first?.id
        appState.saveProfiles()
    }
}

// MARK: - Profile Editor

/// Form-based editor for a single ingest profile.
private struct ProfileEditorView: View {
    @Binding var profile: IngestProfile
    let onSave: () -> Void

    @State private var sourceDirectoriesText: String = ""
    @State private var includeExtensionsText: String = ""
    @State private var excludeExtensionsText: String = ""
    @State private var selectedPreset: String = "custom"
    @State private var didInitialSync = false

    /// Binding that reads/writes selectedPreset as a String tag.
    private var presetBinding: Binding<String> {
        Binding(get: { selectedPreset }, set: { selectedPreset = $0 })
    }

    /// Apply a named preset to the profile's file type filter.
    private func applyPreset(_ preset: String) {
        let filter: FileTypeFilter
        switch preset {
        case "all":          filter = FileTypeRegistry.allFiles
        case "professional": filter = FileTypeRegistry.professionalMedia
        case "images":       filter = FileTypeRegistry.allImages
        case "video":        filter = FileTypeRegistry.allVideo
        case "audio":        filter = FileTypeRegistry.allAudio
        case "documents":    filter = FileTypeRegistry.documents
        default:             return  // custom — leave filter as-is
        }
        profile.fileTypeFilters = filter
        onSave()
    }

    /// Detect which preset matches the current filter, or "custom".
    private func detectPreset(from filter: FileTypeFilter) -> String {
        if filter.includeExtensions == FileTypeRegistry.allFiles.includeExtensions
            && filter.excludeExtensions == FileTypeRegistry.allFiles.excludeExtensions {
            return "all"
        }
        if filter.includeExtensions == FileTypeRegistry.professionalMedia.includeExtensions {
            return "professional"
        }
        if filter.includeExtensions == FileTypeRegistry.allImages.includeExtensions {
            return "images"
        }
        if filter.includeExtensions == FileTypeRegistry.allVideo.includeExtensions {
            return "video"
        }
        if filter.includeExtensions == FileTypeRegistry.allAudio.includeExtensions {
            return "audio"
        }
        if filter.includeExtensions == FileTypeRegistry.documents.includeExtensions {
            return "documents"
        }
        return "custom"
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Profile Name", text: $profile.name)
                    .onChange(of: profile.name) { _, _ in onSave() }
            }

            Section("Source Directories") {
                TextField("Paths (comma-separated)", text: $sourceDirectoriesText)
                    .onChange(of: sourceDirectoriesText) { _, newValue in
                        profile.sourceDirectories = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave()
                    }
                Text("Device paths like /DCIM/Camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("File Type Filters") {
                // Preset picker — quick selection of common filter sets
                Picker("Preset", selection: presetBinding) {
                    Text("All Files").tag("all")
                    Text("Professional Media (RAW + Video)").tag("professional")
                    Text("All Images").tag("images")
                    Text("All Video").tag("video")
                    Text("All Audio").tag("audio")
                    Text("Documents").tag("documents")
                    Text("Custom").tag("custom")
                }
                .onChange(of: presetBinding.wrappedValue) { _, preset in
                    // Skip the initial sync — syncStateFromProfile sets the preset
                    // which would trigger this and overwrite a custom filter.
                    guard didInitialSync else { return }
                    applyPreset(preset)
                }

                if presetBinding.wrappedValue == "custom" {
                    TextField("Include extensions (comma-separated)", text: $includeExtensionsText)
                        .onChange(of: includeExtensionsText) { _, newValue in
                            let include = parseExtensions(newValue)
                            profile.fileTypeFilters = FileTypeFilter(
                                include: include,
                                exclude: profile.fileTypeFilters.excludeExtensions
                            )
                            onSave()
                        }
                    TextField("Exclude extensions (comma-separated)", text: $excludeExtensionsText)
                        .onChange(of: excludeExtensionsText) { _, newValue in
                            let exclude = parseExtensions(newValue)
                            profile.fileTypeFilters = FileTypeFilter(
                                include: profile.fileTypeFilters.includeExtensions,
                                exclude: exclude
                            )
                            onSave()
                        }
                    Text("Leave Include empty to accept all file types.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Show what the preset includes as read-only info
                    let included = profile.fileTypeFilters.includeExtensions
                    if included.isEmpty {
                        Text("Accepts all file types")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(included.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Destination") {
                HStack {
                    TextField("Destination Path", text: $profile.destinationPath)
                        .onChange(of: profile.destinationPath) { _, _ in onSave() }
                    Button("Choose…") {
                        chooseDestination()
                    }
                }
            }

            Section("Naming & Organization") {
                TextField("Naming Template", text: $profile.namingTemplate)
                    .onChange(of: profile.namingTemplate) { _, _ in onSave() }
                Text("Tokens: {date}, {time}, {year}, {month}, {day}, {camera}, {sequence}, {original}, {ext}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let subfolderBinding = Binding<String>(
                    get: { profile.subfolderStructure ?? "" },
                    set: { newValue in
                        profile.subfolderStructure = newValue.isEmpty ? nil : newValue
                        onSave()
                    }
                )
                TextField("Subfolder Structure (optional)", text: subfolderBinding)
                Text("Example: {year}/{month}/{day}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Auto-trigger on device connect", isOn: $profile.autoTrigger)
                    .onChange(of: profile.autoTrigger) { _, _ in onSave() }
                Toggle("Verify checksums after transfer", isOn: $profile.checksumVerification)
                    .onChange(of: profile.checksumVerification) { _, _ in onSave() }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onAppear { syncStateFromProfile() }
        // Re-sync text fields whenever the selected profile changes.
        // Comparing by ID is sufficient — the text fields are the source of
        // truth while editing; we only need to reset them on profile switch.
        .onChange(of: profile.id) { _, _ in syncStateFromProfile() }
        // Also sync when the profile is replaced externally (e.g., undo/redo).
        .onChange(of: profile.name) { _, _ in
            // Only sync the non-name fields — name is directly bound.
            sourceDirectoriesText = profile.sourceDirectories.joined(separator: ", ")
        }    }

    /// Sync @State text fields from the current profile binding.
    /// Called on appear and when the profile selection changes.
    private func syncStateFromProfile() {
        sourceDirectoriesText = profile.sourceDirectories.joined(separator: ", ")
        includeExtensionsText = profile.fileTypeFilters.includeExtensions.joined(separator: ", ")
        excludeExtensionsText = profile.fileTypeFilters.excludeExtensions.joined(separator: ", ")
        selectedPreset = detectPreset(from: profile.fileTypeFilters)
        // Mark initial sync complete so onChange doesn't overwrite the filter
        DispatchQueue.main.async { didInitialSync = true }
    }

    private func parseExtensions(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the destination folder for transferred files."

        if panel.runModal() == .OK, let url = panel.url {
            profile.destinationPath = url.path
            onSave()
        }
    }
}

/// Transfer history tab — searchable log of past transfer sessions.
private struct TransferHistoryTab: View {
    @State private var sessions: [TransferSession] = []
    @State private var isLoading = true
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search by device or profile…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading history…")
                Spacer()
            } else if filteredSessions.isEmpty {
                Spacer()
                ContentUnavailableView(
                    searchText.isEmpty ? "No Transfer History" : "No Results",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        searchText.isEmpty
                            ? "Transfer history will appear here after your first ingest."
                            : "No sessions match \"\(searchText)\"."
                    )
                )
                Spacer()
            } else {
                List(filteredSessions) { session in
                    SessionRow(session: session)
                }
                .listStyle(.plain)
            }
        }
        .task { await loadSessions() }
    }

    private var filteredSessions: [TransferSession] {
        guard !searchText.isEmpty else { return sessions }
        let query = searchText.lowercased()
        return sessions.filter {
            $0.deviceName.lowercased().contains(query) ||
            ($0.profileName?.lowercased().contains(query) ?? false)
        }
    }

    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }

        guard let db = try? AppDatabase() else { return }
        let store = TransferStore(database: db.dbQueue)
        sessions = (try? store.fetchRecentSessions()) ?? []
    }
}

/// A single row in the transfer history list.
private struct SessionRow: View {
    let session: TransferSession

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Image(systemName: session.failedFiles == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(session.failedFiles == 0 ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.deviceName)
                        .font(.headline)
                    if let profile = session.profileName {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(profile)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Label("\(session.successfulFiles) files", systemImage: "doc")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Label(ByteFormatter.format(session.totalBytes), systemImage: "internaldrive")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Label(session.formattedSpeed, systemImage: "speedometer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.dateFormatter.string(from: session.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.formattedDuration)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if session.failedFiles > 0 {
                    Text("\(session.failedFiles) failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// General settings tab.
private struct SettingsTab: View {
    @AppStorage("preferredEngine") private var preferredEngine = "auto"
    @AppStorage("checksumEnabled") private var checksumEnabled = true
    @AppStorage("updateCheckEnabled") private var updateCheckEnabled = false

    var body: some View {
        Form {
            Section("Transfer Engine") {
                Picker("Default engine", selection: $preferredEngine) {
                    Text("Auto (recommended)").tag("auto")
                    Text("MTP only").tag("mtp")
                    Text("ADB only").tag("adb")
                }
            }

            Section("Verification") {
                Toggle("Verify checksums after transfer", isOn: $checksumEnabled)
            }

            Section("Updates") {
                Toggle("Check for updates on launch", isOn: $updateCheckEnabled)
            }

            Section("Privacy") {
                Text("SnapHaul makes no network connections for core functionality. Update checks and crash reporting are opt-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
