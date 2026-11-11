// Settings (⌘,): one tab per topic, one grouped form per tab.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, folders, models, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .folders: "Folders"; case .models: "Models"; case .privacy: "Privacy"; case .about: "About" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .folders: "folder"; case .models: "cpu"; case .privacy: "hand.raised"; case .about: "info.circle" }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                Group {
                    switch tab {
                    case .general: GeneralSettings()
                    case .folders: FoldersSettings()
                    case .models: ModelsSettings()
                    case .privacy: PrivacySettings()
                    case .about: AboutSettings()
                    }
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .frame(width: 560, height: 420)
        .noInitialFocus()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var onlyOnPower = false
    private let theme = ThemeStore.shared

    var body: some View {
        Form {
            Section("Indexing") {
                Toggle("Index only when plugged in", isOn: $onlyOnPower)
                    .onChange(of: onlyOnPower) { _, on in Task { try? await model.handle?.setIndexOnlyOnPower(on: on) } }
                    .help("Wait for power before reading files in the background")
                LabeledContent("Background work") {
                    Button(model.isPaused ? "Resume Indexing" : "Pause Indexing") { model.togglePause() }
                }
                Text("SmartAsset also slows down by itself when your Mac is on battery, warm, low on memory, or while you are working.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                LabeledContent("Accent") {
                    HStack(spacing: Space.xs) {
                        ForEach(Theme.all) { t in
                            AccentSwatch(theme: t, selected: theme.themeID == t.id) { theme.themeID = t.id }
                        }
                    }
                }
                Text("Light and dark mode follow your Mac.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                shortcut("Quick Look", "Space")
                shortcut("Open in Viewer", "Return")
                shortcut("Rate", "0–5")
                shortcut("Pick, Reject, Clear Flag", "P  X  U")
                shortcut("Search", "⌘F")
                shortcut("Search Everywhere", "⌘K")
                shortcut("Add Folder", "⇧⌘O")
            }
        }
        .formStyle(.grouped)
        .task { onlyOnPower = model.handle?.indexOnlyOnPower() ?? false }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

private struct FoldersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if model.folders.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder",
                                       description: Text("Add the folders you want to search. Nothing is indexed until you do."))
            } else {
                List(selection: $selection) {
                    ForEach(model.folders) { folder in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(folder.displayName, systemImage: folder.volumeOnline ? "folder" : "externaldrive.badge.xmark")
                                Spacer()
                                Text(statusText(folder)).font(.callout).foregroundStyle(.secondary)
                            }
                            Text(folder.path ?? "On “\(folder.volumeName)” (not connected)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("\(folder.assetCount.formatted()) files · \(Format.fileSize(folder.totalSize))\(folder.excludes.isEmpty ? "" : " · \(folder.excludes.count) excluded")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(folder.id)
                        .opacity(folder.enabled ? 1 : 0.6)
                    }
                }
            }
            Divider()
            HStack {
                Button("Add Folder…") { Task { await model.chooseFolders() } }
                Spacer()
                Button("Exclude Subfolders…") { if let f = selected { model.folderToExclude = f } }.disabled(selected == nil)
                Button(selected?.enabled == false ? "Turn On" : "Turn Off") { if let f = selected { Task { await model.setFolderEnabled(f.id, !f.enabled) } } }.disabled(selected == nil)
                Button("Remove…", role: .destructive) { if let f = selected { model.folderToRemove = f } }.disabled(selected == nil)
            }
            .padding(Space.md)
        }
    }

    private var selected: FolderDto? { model.folders.first { $0.id == selection } }

    private func statusText(_ f: FolderDto) -> String {
        if !f.enabled { return "Off" }
        if !f.volumeOnline { return "Drive not connected" }
        switch f.scanState {
        case .scanning: return "Looking for files…"
        case .error: return "Can’t read"
        case .pending: return "Waiting"
        case .idle: return f.pendingCount > 0 ? "Indexing" : "Ready"
        }
    }
}

private struct ModelsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var removing = false
    private var memoryGB: Double { ModelCatalog.memoryGigabytes(bytes: ProcessInfo.processInfo.physicalMemory) }

    var body: some View {
        let recommended = ModelCatalog.recommendedTranscription(memoryGigabytes: memoryGB)
        let download = model.modelDownload
        Form {
            Section {
                Text("This Mac has \(Int(memoryGB.rounded())) GB of memory. A model is downloaded only when you choose Download Model, stays on this Mac, and can be removed at any time. Once installed, it works without an internet connection.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(ModelEntry.Job.embedding.rawValue) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text(download.model.name).font(.headline)
                        Spacer()
                        downloadControl(download)
                    }
                    Text("One model that understands words and pictures, so you can search by describing what you want.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(ModelDownload.size(download.model.totalBytes)) · \(download.model.publisher) · version \(download.model.shortCommit)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Uses about 1.2 GB of memory while it works (measured on a 16 GB Mac).")
                        .font(.caption).foregroundStyle(.secondary)
                    downloadStatus(download)
                }
                .padding(.vertical, 2)
            }
            Section(ModelEntry.Job.transcription.rawValue) {
                ForEach(ModelCatalog.entries.filter { $0.job == .transcription }) { entry in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            Text(entry.name).font(.headline)
                            if entry.id == recommended { Text("Recommended for this Mac").font(.caption).padding(.horizontal, Space.sm).padding(.vertical, 2).background(Palette.accent.opacity(0.18), in: Capsule()) }
                            Spacer()
                            Button("Download Model…") {}.disabled(true).help(unavailableText(entry))
                        }
                        Text(entry.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(ModelCatalog.sizeText(entry.approxGigabytes)) · \(entry.license)").font(.caption).foregroundStyle(.secondary)
                        if case .planned(let note) = entry.availability { Text(note).font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { download.refresh() }
        .sheet(isPresented: $confirming) { DownloadConfirmation(download: download) { confirming = false } }
        .confirmationDialog("Remove \(download.model.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await download.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Search by meaning stops until you download it again. Your library and your files are not touched.")
        }
    }

    @ViewBuilder private func downloadControl(_ download: ModelDownload) -> some View {
        switch download.state {
        case .notInstalled, .failed:
            Button("Download Model…") { confirming = true }
                .help("See what will be downloaded, then choose Download")
        case .downloading, .verifying:
            Button("Cancel") { download.cancel() }
                .help("Stop the download; nothing is installed")
        case .installed:
            Button("Remove…") { removing = true }
                .help("Delete the model from this Mac")
        }
    }

    @ViewBuilder private func downloadStatus(_ download: ModelDownload) -> some View {
        switch download.state {
        case .notInstalled:
            EmptyView()
        case .downloading(let received, let total):
            ProgressView(value: Double(received), total: Double(max(total, 1))) {
                Text("Downloading \(ModelDownload.size(received)) of \(ModelDownload.size(total))").font(.caption)
            }
        case .verifying:
            ProgressView { Text("Checking every file against its published checksum…").font(.caption) }
        case .installed:
            Label("Installed and verified · works offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unavailableText(_ entry: ModelEntry) -> String {
        if case .planned(let note) = entry.availability { return note }
        return "Download"
    }
}

/// What will be downloaded, shown before anything is (owner's rule: name, publisher, version, size, disk space).
private struct DownloadConfirmation: View {
    let download: ModelDownload
    let close: () -> Void

    var body: some View {
        let m = download.model
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Download \(m.name)?").font(.title3.weight(.semibold))
            Form {
                LabeledContent("Model", value: m.name)
                LabeledContent("Publisher", value: m.publisher)
                LabeledContent("Source", value: "huggingface.co/\(m.repository)")
                LabeledContent("Version", value: "commit \(m.shortCommit) (pinned)")
                LabeledContent("Download size", value: "\(ModelDownload.size(m.totalBytes)) in \(m.files.count) files")
                LabeledContent("Disk space needed", value: freeText)
                LabeledContent("License", value: m.license)
            }
            .formStyle(.grouped)
            Text("SmartAsset connects to Hugging Face only for this download, over HTTPS, and checks every file against its published SHA-256 before installing it. Nothing about your files is sent. Afterwards, search by meaning works without an internet connection.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { download.start(); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!download.hasRoom)
                    .help(download.hasRoom ? "Download and install \(m.name)" : "Free up space first")
            }
        }
        .padding(Space.lg)
        .frame(width: 520)
    }

    private var freeText: String {
        let need = ModelDownload.size(download.model.requiredFreeBytes)
        guard let free = download.freeBytes else { return need }
        return "\(need) (\(ModelDownload.size(free)) free)"
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
                LabeledContent("Library", value: AppModel.dataDirectory.path)
            }
            Section {
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.dataDirectory]) }
                Text("What SmartAsset does and does not do with your files is on the Privacy tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// What stays on the Mac (plan H4). Every sentence here is true of the app as built, and `tools/audit-network.sh`
/// checks the one that can be checked mechanically: no networking code.
private struct PrivacySettings: View {
    @State private var librarySize: String?

    var body: some View {
        Form {
            Section {
                Label("Everything stays on your Mac.", systemImage: "lock.shield")
                    .font(.headline)
                fact("No account and no sign-in.")
                fact("Nothing about your files, thumbnails, tags, notes or searches is sent anywhere.")
                fact("SmartAsset connects to the internet only when you choose Download Model, and only to Hugging Face (huggingface.co), to fetch that model over HTTPS. Every file is checked against its published checksum before it is installed. There are no automatic downloads or update checks.")
                fact("Once a model is installed, indexing, search by meaning and everything else work with Wi‑Fi off.")
                fact("No analytics, and no crash reports are sent.")
                fact("Your files are read where they are. They are never copied, and never changed.")
                fact("The one thing that moves a file is Move to Trash on the Duplicates page, and only after you review the files and confirm. Files go to the Trash, never straight to deletion.")
            }
            Section("Where SmartAsset keeps what it learned") {
                LabeledContent("Library", value: (AppModel.dataDirectory.path as NSString).abbreviatingWithTildeInPath)
                LabeledContent("Size", value: librarySize ?? "Measuring…")
                Text("This is the index, the thumbnails, the words read in your pictures and videos, and your ratings, tags and notes. They are read on this Mac. Removing a folder from SmartAsset deletes its entries here and leaves the files alone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.dataDirectory]) }
            }
            Section("Check it yourself") {
                Text("Open Activity Monitor and look under Network, or use a firewall such as Little Snitch. SmartAsset should appear only while a model you chose is downloading.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { librarySize = await Self.measure(AppModel.dataDirectory) }
    }

    private func fact(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Total size of the library folder, counted off the main thread.
    nonisolated private static func measure(_ url: URL) async -> String {
        await Task.detached(priority: .utility) { Format.fileSize(folderSize(url)) }.value
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

private struct AccentSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    private var fill: AnyShapeStyle {
        if theme.shades == nil {
            return AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
        }
        return AnyShapeStyle(theme.accent)
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(theme.name)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
