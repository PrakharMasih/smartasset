// The Search page before anything is typed: how ready search by meaning is, recent searches, and a few ideas to try.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

struct SearchHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var newest: [AssetSummaryDto] = []

    /// Creator-style questions, shown only while search by meaning is on (they mean nothing to a words-only search).
    private static let ideas = [
        "people talking to camera", "close-up of hands", "city street at night",
        "drone shot over water", "someone laughing", "a plain white background",
    ]

    var body: some View {
        VStack(spacing: Space.lg) {
            HStack(spacing: Space.md) {
                ScopeMenu()
                KindChoices()
            }
            status
            NewestFiles(items: newest)
            if !model.recentSearches.items.isEmpty { recents }
            if canTryIdeas { ideas }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, Space.section)
        // The newest files follow the kind and the scope. Loaded here, because a task on a view that may draw nothing never runs.
        .task(id: model.resultsGeneration) {
            guard let handle = model.handle, let ids = model.results?.idsIn(offset: 0, limit: 6), !ids.isEmpty else { newest = []; return }
            let found = (try? await handle.summaries(assetIds: ids)) ?? []
            let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            newest = ids.compactMap { byID[$0] }
        }
    }

    private var canTryIdeas: Bool {
        switch model.searchReadiness {
        case .ready, .preparing: true
        case .loading, .wordsOnly: false
        }
    }

    // MARK: Status of search by meaning

    private var status: some View {
        HStack(spacing: Space.sm) {
            switch model.searchReadiness {
            case .ready:
                Image(systemName: "sparkles").foregroundStyle(Palette.accentText)
                Text("Search by meaning is on · \(fileCount)").foregroundStyle(.secondary)
                preview
            case .preparing(let left):
                ProgressView().controlSize(.small)
                Text("Preparing search by meaning · \(left.formatted()) \(left == 1 ? "file" : "files") left. Names, tags and notes work now.")
                    .foregroundStyle(.secondary)
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                    .controlSize(.small)
                    .help(model.isPaused ? "Continue indexing (⌥⌘P)" : "Stop indexing until you resume (⌥⌘P)")
                preview
            case .loading:
                ProgressView().controlSize(.small)
                Text("Getting search by meaning ready…").foregroundStyle(.secondary)
            case .wordsOnly(let reason):
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                Text(reason ?? "Searching by name, folder, tag and note. Search by meaning needs the Model.")
                    .foregroundStyle(.secondary)
                Button("Set Up…") { model.settingsTab = .models; openSettings() }
                    .controlSize(.small)
                    .help("Choose the Model for search by meaning")
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var fileCount: String {
        let n = Int(model.stats?.total ?? 0)
        return "\(n.formatted()) \(n == 1 ? "file" : "files")"
    }

    /// Search by meaning has not been measured on creator media yet (PLAN §16, 2026-11-07), and the page says so.
    private var preview: some View {
        Text("Preview")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Space.xs + 2)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("Search by meaning is new. It has not been tested on creator media yet, so a match can be missing or surprising.")
            .accessibilityLabel("Preview")
    }

    // MARK: Recent searches and ideas

    private var recents: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Recent Searches").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.recentSearches.clear() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Forget recent searches")
            }
            ForEach(model.recentSearches.items.prefix(5), id: \.self) { words in
                HStack(spacing: Space.sm) {
                    Button { model.search(for: words) } label: {
                        Label(words, systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Search for “\(words)” again")
                    Button { model.recentSearches.remove(words) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove this recent search")
                        .accessibilityLabel("Remove “\(words)”")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var ideas: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Try").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            FlowChips(items: Self.ideas) { words in model.search(for: words) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kind choice for the home page (the results page has its own).
private struct KindChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Kind", selection: Binding<MediaKind?>(
            get: { model.filters.kinds.count == 1 ? model.filters.kinds.first : nil },
            set: { model.filters.kinds = $0.map { [$0] } ?? [] })) {
            Text("All").tag(MediaKind?.none)
            Text("Images").tag(MediaKind?.some(.image))
            Text("Videos").tag(MediaKind?.some(.video))
            Text("Audio").tag(MediaKind?.some(.audio))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Search only images, videos or audio")
        .accessibilityLabel("Kind")
    }
}

/// Words as small buttons that wrap onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Space.sm) {
            ForEach(items, id: \.self) { words in
                Button { action(words) } label: {
                    Text(words)
                        .font(.callout)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.xs + 2)
                        .background(Palette.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Search for “\(words)”")
            }
        }
    }
}

/// The newest files as real pictures: a way in for people who do not know what to type yet. Follows the kind and the scope.
private struct NewestFiles: View {
    @Environment(AppModel.self) private var model
    let items: [AssetSummaryDto]

    private static let size: CGFloat = 100

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(model.searchScope == .everywhere ? "Newest Files" : "Newest in \(model.searchScopeName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: Space.sm) {
                        ForEach(items, id: \.id) { item in
                            Button { model.openViewer(item.id) } label: {
                                ThumbnailImage(id: item.id, rev: item.thumbRev, handle: model.handle, fill: true)
                                    .frame(width: Self.size, height: Self.size)
                                    .background(Color(nsColor: .quaternarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                                    .opacity(item.volumeOnline && !item.missing ? 1 : 0.5)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(item.name) in the Viewer")
                            .accessibilityLabel("Open \(item.name)")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
