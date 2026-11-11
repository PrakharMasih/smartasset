// The Search page (plan S1, S12, S13): the start page and the heart of the app.
// One field. Before anything is typed the page invites a description; once words are typed the field moves up and the
// matches fill the same grid the library uses, so selecting, Quick Look, the Viewer and drag-out all work as they do there.
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

struct SearchPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        let home = !model.searchHasQuestion
        VStack(spacing: 0) {
            if home {
                Spacer(minLength: Space.xl)
                SearchHeading()
            }
            // The field stays in the same place in this stack in both layouts, so typing the first letter never loses focus.
            field(home: home)
            if home {
                SearchHome()
                Spacer(minLength: Space.xl)
                Spacer(minLength: Space.xl)
            } else {
                resultsBar
                if model.showsFilterBar || !model.filters.isEmpty { FilterBar() }
                FilesView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pictures stand out on a deeper backdrop; the home adds a soft wash of the accent behind the field.
        .background {
            ZStack(alignment: .top) {
                Surface.content
                if home { Surface.glow }
            }
            .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: home) // motion: ok, the field moves; Reduce Motion skips it
        .task {
            // The window clears focus right after it opens; ask once that is done.
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
        .gridArea("search")
    }

    // MARK: The field

    private func field(home: Bool) -> some View {
        @Bindable var model = model
        return HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(home ? .title2 : .title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let like = model.searchLike {
                LikeChip(name: like.name)
            }
            TextField(placeholder, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(home ? .title : .title2)
                .focused($focused)
                .onSubmit { model.commitSearch() }
                .onKeyPress(.downArrow) { focusResults() ? .handled : .ignored }
                .onKeyPress(.escape) { escape() }
                .accessibilityLabel("Search")
            if !model.searchText.isEmpty || model.searchLike != nil {
                Button { model.searchText = ""; model.clearLike(); focused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the search (⎋)")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: home ? 56 : 44)
        .fieldSurface(cornerRadius: home ? Radius.lg : Radius.md)
        .overlay(RoundedRectangle(cornerRadius: home ? Radius.lg : Radius.md).strokeBorder(focused ? Palette.accent.opacity(0.6) : Color.clear, lineWidth: 2))
        .frame(maxWidth: home ? 680 : .infinity)
        .padding(.horizontal, home ? Space.section : Space.lg)
        .padding(.top, home ? 0 : Space.md)
        .padding(.bottom, home ? Space.md : Space.sm)
    }

    private var placeholder: String {
        if model.searchLike != nil { return "Add words to search by words instead" }
        return switch model.searchReadiness {
        case .ready, .preparing: "Describe what you’re looking for"
        case .loading, .wordsOnly: "Search by name, folder, tag or note"
        }
    }

    /// Escape clears the words; with nothing to clear it leaves the field.
    private func escape() -> KeyPress.Result {
        if model.searchLike != nil {
            model.clearLike()
        } else if model.hasSearchWords {
            model.searchText = ""
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        return .handled
    }

    /// ↓ moves from the field into the results, selecting the first file when nothing is selected.
    private func focusResults() -> Bool {
        guard model.resultCount > 0, let window = NSApp.keyWindow, let view = window.contentView?.firstDescendant(where: { $0 is NSCollectionView || $0 is NSTableView }) else { return false }
        window.makeFirstResponder(view)
        if model.selectedIDs.isEmpty {
            if let grid = view as? AssetCollectionView {
                // Select in the grid itself, so its keys (Return, Space, 0–5) act on this file at once.
                grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
                grid.coordinator?.selectionChanged()
            } else if let first = model.source?.id(at: 0) {
                model.selectedIDs = [first]
            }
        }
        return true
    }

    // MARK: Over the results

    private var resultsBar: some View {
        HStack(spacing: Space.md) {
            KindScope()
            ScopeMenu()
            Spacer(minLength: Space.sm)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs + 2)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        let count = model.resultCount
        let noun = count == 1 ? "file" : "files"
        if model.searchLike != nil { return "More Like This · \(count.formatted()) \(noun)" }
        switch model.searchReadiness {
        case .ready, .preparing: return "Best Matches · \(count.formatted()) \(noun)"
        case .loading, .wordsOnly: return "Matches · \(count.formatted()) \(noun)"
        }
    }
}

/// "Like IMG_0042.jpg ✕": More Like This (S7) as a token in the field, so it is clear what the results are looking like.
private struct LikeChip: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "sparkle.magnifyingglass").imageScale(.small)
            Text("Like \(name)").lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            Button { model.clearLike() } label: { Image(systemName: "xmark").imageScale(.small) }
                .buttonStyle(.borderless)
                .help("Stop looking for files like this one (⎋)")
                .accessibilityLabel("Stop looking for files like \(name)")
        }
        .font(.callout)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Palette.accent.opacity(0.18), in: Capsule())
        .fixedSize()
        .help("More Like This: the files whose pictures look most like \(name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("More like \(name)")
    }
}

/// The large title over the field, and one line that says what the field understands.
private struct SearchHeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.sm) {
            Text("What are you looking for?")
                .font(.system(size: 32, weight: .semibold))
                .tracking(-0.4)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.section)
        .padding(.bottom, Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        switch model.searchReadiness {
        case .ready, .preparing: "Describe a picture or a scene. SmartAsset looks at what is in your photos and videos."
        case .loading, .wordsOnly: "Search by file name, folder, tag or note."
        }
    }
}

/// The same kind scope as every other page of files, without its own bar background (it sits in the results bar).
private struct KindScope: View {
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
        .help("Show only images, videos or audio")
        .accessibilityLabel("Kind")
    }
}

/// "in: Everywhere ▾": limits the search to a folder, a collection or a tag.
struct ScopeMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Everywhere") { model.searchScope = .everywhere }
            if !model.folders.isEmpty {
                Divider()
                ForEach(model.folders) { folder in
                    Button(folder.displayName) { model.searchScope = .folder(folder.id) }
                }
            }
            if !model.collections.isEmpty {
                Divider()
                ForEach(model.collections) { c in
                    Button(c.name) { model.searchScope = .collection(c.id) }
                }
            }
            if !model.tags.isEmpty {
                Divider()
                ForEach(model.tags) { t in
                    Button("#\(t.name)") { model.searchScope = .tag(t.name) }
                }
            }
        } label: {
            Label("in \(model.searchScopeName)", systemImage: model.searchScope == .everywhere ? "globe" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose where to search")
        .accessibilityLabel("Search in \(model.searchScopeName)")
    }
}

extension NSView {
    /// The first view below this one that matches, searching depth first.
    func firstDescendant(where match: (NSView) -> Bool) -> NSView? {
        for sub in subviews {
            if match(sub) { return sub }
            if let found = sub.firstDescendant(where: match) { return found }
        }
        return nil
    }
}
