// The sidebar: where files live (plan L1a), and the lists you made (O2, O3).
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI
import Workers
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let item = $0 { model.sidebar = item } })) {
            // Search is the start page and the heart of the app: it sits first, alone, above everything else.
            Section {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                    .help("Describe what you are looking for (⌘F)")
            }

            Section("Library") {
                row(.all, "All Files", "photo.on.rectangle.angled", count: model.stats?.total)
                if let missing = model.stats?.missing, missing > 0 {
                    row(.missing, "Missing", "questionmark.circle", count: missing)
                }
            }

            if (model.stats?.total ?? 0) > 1 {
                Section("Cleanup") {
                    row(.duplicates, "Duplicates", "square.on.square",
                        count: model.duplicates.map { Int64($0.exact.count + $0.similar.count) })
                }
            }

            Section {
                ForEach(model.folders) { folder in
                    FolderRow(folder: folder)
                        .tag(SidebarItem.folder(folder.id))
                }
            } header: {
                header("Folders", help: "Add a folder to the library (⇧⌘O)") { Task { await model.chooseFolders() } }
            }

            Section {
                ForEach(model.collections) { c in
                    Label(c.name, systemImage: "rectangle.stack")
                        .badge(Int(c.assetCount))
                        .tag(SidebarItem.collection(c.id))
                        .contextMenu {
                            Button("Rename…") { model.renaming = .collection(c.id, c.name) }
                            Divider()
                            Button("Delete Collection", role: .destructive) { Task { await model.deleteCollection(c.id) } }
                        }
                        .onDrop(of: [AssetDrag.type], isTargeted: nil) { providers in
                            AssetDrag.ids(from: providers) { ids in Task { await model.addToCollection(c.id, ids: ids) } }
                            return true
                        }
                }
            } header: {
                header("Collections", help: "Make a new collection (⌘N)") { model.promptNewCollection() }
            }

            if !model.smartCollections.isEmpty {
                Section("Smart Collections") {
                    ForEach(model.smartCollections) { c in
                        Label(c.name, systemImage: "gearshape.2")
                            .tag(SidebarItem.smart(c.id))
                            .contextMenu {
                                Button("Rename…") { model.renaming = .smart(c.id, c.name) }
                                Divider()
                                Button("Delete Smart Collection", role: .destructive) { Task { await model.deleteSmartCollection(c.id) } }
                            }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .badge(Int(tag.assetCount))
                            .tag(SidebarItem.tag(tag.name))
                            .contextMenu {
                                Button("Rename Tag…") { model.renaming = .tag(tag.name) }
                                Divider()
                                Button("Delete Tag", role: .destructive) { Task { try? await model.handle?.deleteTag(name: tag.name); await model.refreshSidebarData(); model.requery() } }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Library")
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int64?) -> some View {
        Label(title, systemImage: symbol)
            .badge(count.map { Int($0) } ?? 0)
            .tag(item)
    }

    private func header(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(help)
                .accessibilityLabel("Add \(title.dropLast())")
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderDto

    var body: some View {
        HStack(spacing: Space.sm) {
            Label {
                Text(folder.displayName).lineLimit(1)
            } icon: {
                Image(systemName: icon)
            }
            Spacer(minLength: Space.xs)
            status
        }
        .opacity(folder.enabled && folder.volumeOnline ? 1 : 0.55)
        .help(helpText)
        .contextMenu {
            Button("Show in Finder") { if let path = folder.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                .disabled(folder.path == nil)
            Button("Rescan") { Task { await model.rescan(folder.id) } }
                .disabled(!folder.volumeOnline || !folder.enabled)
            Divider()
            Button("Exclude Subfolders…") { model.folderToExclude = folder }
            Button(folder.enabled ? "Turn Off" : "Turn On") { Task { await model.setFolderEnabled(folder.id, !folder.enabled) } }
            Divider()
            Button("Remove Folder…", role: .destructive) { model.folderToRemove = folder }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        if !folder.volumeOnline { return "externaldrive.badge.xmark" }
        return folder.volumeName.isEmpty || folder.displayName == folder.volumeName ? "externaldrive" : "folder"
    }

    @ViewBuilder private var status: some View {
        if !folder.volumeOnline {
            Image(systemName: "powerplug").foregroundStyle(.secondary).help("Plug in “\(folder.volumeName)”")
        } else if folder.scanState == .error {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(folder.lastError ?? "This folder can’t be read.")
        } else if folder.scanState == .scanning {
            ProgressView().controlSize(.mini)
        } else if folder.lastError != nil {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(folder.lastError ?? "")
        } else {
            Text(folder.assetCount.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var helpText: String {
        var lines = [folder.path ?? "On “\(folder.volumeName)” (not connected)"]
        lines.append("\(folder.assetCount.formatted()) files · \(Format.fileSize(folder.totalSize))")
        if !folder.enabled { lines.append("Turned off") }
        if let error = folder.lastError { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}

/// Files dragged from the grid onto a collection in the sidebar.
enum AssetDrag {
    static let type = UTType(importedAs: "com.smartasset.asset-id")

    static func ids(from providers: [NSItemProvider], completion: @escaping @MainActor ([Int64]) -> Void) {
        let found = LockedBox<[Int64]>([])
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                if let data, let text = String(data: data, encoding: .utf8), let id = Int64(text) {
                    found.withLock { $0.append(id) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ids = found.withLock { $0 }
            MainActor.assumeIsolated { if !ids.isEmpty { completion(ids) } }
        }
    }
}
