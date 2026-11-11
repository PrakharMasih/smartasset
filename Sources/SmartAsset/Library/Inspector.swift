// The inspector (plan V5): details of the selection, and the place to rate, flag, label, tag and annotate (O1).
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.selectedIDs.isEmpty {
                VStack(spacing: Space.xs) {
                    Image(systemName: "sidebar.right").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("No Selection").font(.headline).foregroundStyle(.secondary)
                    Text("Select a file to see its details.").font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else if model.selectedIDs.count == 1 {
                if let detail = model.selectedDetail {
                    SingleInspector(detail: detail).id(detail.summary.id)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                MultiInspector()
            }
        }
        .accessibilityLabel("Inspector")
    }
}

// MARK: - One file

private struct SingleInspector: View {
    @Environment(AppModel.self) private var model
    let detail: AssetDetailDto
    @State private var preview: NSImage?
    /// Why this file came up for the words on the Search page (S11); nil off the Search page or before the answer.
    @State private var why: MatchExplanationDto?
    /// C1 labels and C2 content of this file, worked out when it is selected.
    @State private var labels: [LabelScoreDto] = []
    @State private var content: PictureContentDto?
    /// S2: where this video's scenes start (milliseconds).
    @State private var scenes: [Int64] = []

    private var s: AssetSummaryDto { detail.summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header.gridProbe("header", area: "inspector")
                if s.missing || !s.volumeOnline || s.probeState == .failed || s.probeState == .pending { statusNotice.gridProbe("notice", area: "inspector") }
                if showsWhy { whyMatched.gridProbe("why", area: "inspector") }
                organize.gridProbe("organize", area: "inspector")
                TagsEditor(ids: [s.id], tags: detail.tags).gridProbe("tags", area: "inspector")
                NotesEditor(id: s.id, initial: detail.notes).gridProbe("notes", area: "inspector")
                if !labels.isEmpty { shows.gridProbe("shows", area: "inspector") }
                if scenes.count > 1 { moments.gridProbe("moments", area: "inspector") }
                collections.gridProbe("collections", area: "inspector")
                detailsSection.gridProbe("details", area: "inspector")
                if let exif = exifPairs, !exif.isEmpty { section("Camera Settings", exif).gridProbe("camera", area: "inspector") }
                fileSection.gridProbe("file", area: "inspector")
            }
            .padding(Space.lg)
        }
        .gridArea("inspector", inset: Space.lg)
        .task(id: "\(s.id)-\(s.thumbRev)") { await loadPreview() }
        .task(id: "\(s.id)|\(model.semantic == .ready)") {
            labels = (try? await model.handle?.labelsOf(assetId: s.id)) ?? []
            content = (try? await model.handle?.pictureContent(assetId: s.id)) ?? nil
            scenes = s.kind == .video ? ((try? await model.handle?.sceneTimes(assetId: s.id)) ?? []) : []
        }
        .task(id: "\(s.id)|\(model.sidebar == .search ? model.searchText : "")|\(model.semantic == .ready)") {
            // Wait for typing and selection to settle: each answer embeds the words with the model, which is not worth
            // doing for every keystroke or for every file the arrow keys pass over.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            why = await model.explainMatch(s.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md).fill(.quaternary)
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: Radius.md))
                } else {
                    Image(systemName: s.probeState == .failed ? "exclamationmark.triangle" : s.kind.symbol)
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 200)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openViewer(s.id) }
            .accessibilityLabel("Preview of \(s.name)")
            .help("Double-click to open in the Viewer")
            Text(s.name).font(.headline).lineLimit(3).textSelection(.enabled)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            if model.semantic == .ready, s.kind != .audio, !s.missing {
                Button { Task { await model.moreLikeThis(s.id) } } label: { Label("More Like This", systemImage: "sparkle.magnifyingglass") }
                    .controlSize(.small)
                    .help("Find files that look like this one (⌥⌘F)")
            }
        }
    }

    // MARK: Shows (C1)

    /// The words this picture shows, from its description; each one searches the library for it.
    @ViewBuilder private var shows: some View {
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Shows").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: Space.xs) {
                    ForEach(labels, id: \.name) { label in
                        Button(label.name) { model.searchLabel(label.name) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Search your library for “\(label.name)”")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shows")
        }
    }

    // MARK: Moments (S2)

    /// Where this video's scenes start; each opens the Viewer there.
    @ViewBuilder private var moments: some View {
        if scenes.count > 1 {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Moments").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: Space.xs) {
                    ForEach(scenes, id: \.self) { ms in
                        Button(Format.duration(milliseconds: ms)) { model.openViewer(s.id, atSeconds: Double(ms) / 1000) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .monospacedDigit()
                            .help("Play from \(Format.duration(milliseconds: ms))")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Moments")
        }
    }

    // MARK: Why this matched (S11)

    /// Only a section with something to say takes a place in the stack (an empty one would leave a double gap).
    private var showsWhy: Bool {
        guard model.sidebar == .search else { return false }
        if let like = model.searchLike { return like.id != s.id }
        guard let why else { return false }
        return !why.words.isEmpty || why.meaning != nil
    }

    @ViewBuilder private var whyMatched: some View {
        if model.sidebar == .search, let like = model.searchLike, like.id != s.id {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Why This Matched").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Label("Looks like “\(like.name)”", systemImage: "sparkles").font(.callout)
            }
        } else if model.sidebar == .search, let why, !why.words.isEmpty || why.meaning != nil {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Why This Matched").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(why.words.enumerated()), id: \.offset) { _, hit in
                    Label(sentence(for: hit), systemImage: symbol(for: hit.place))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let meaning = why.meaning { meaningRow(meaning) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func sentence(for hit: WordMatchDto) -> String {
        let word = "“\(hit.word)”"
        let snippet = hit.snippet.map { ": \($0)" } ?? ""
        switch hit.place {
        case .name: return "\(word) is in the name"
        case .tag: return "\(word) is a tag"
        case .note: return "\(word) is in your note\(snippet)"
        case .textInPicture: return "\(word) is written in the \(s.kind == .video ? "video" : "picture")\(snippet)"
        case .folder: return "\(word) is in a folder name"
        }
    }

    private func symbol(for place: MatchPlace) -> String {
        switch place {
        case .name: "textformat"
        case .tag: "tag"
        case .note: "note.text"
        case .textInPicture: "text.viewfinder"
        case .folder: "folder"
        }
    }

    @ViewBuilder private func meaningRow(_ meaning: MeaningMatchDto) -> some View {
        Label(meaning.strong ? "Looks like what you described" : "Looks a little like what you described", systemImage: "sparkles")
            .font(.callout)
        if let at = meaning.momentMs, s.kind == .video {
            HStack(spacing: Space.sm) {
                Text("Closest at \(Format.duration(milliseconds: at))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Play from \(Format.duration(milliseconds: at))") { model.openViewer(s.id) }
                    .controlSize(.small)
                    .help("Open the video at the moment that looks most like your words")
            }
        }
    }

    private var subtitle: String {
        var parts = [s.kind.label]
        if let dims = Format.dimensions(width: s.width, height: s.height) { parts.append(dims) }
        if let ms = s.durationMs { parts.append(Format.duration(milliseconds: ms)) }
        parts.append(Format.fileSize(s.size))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusNotice: some View {
        if s.missing {
            notice("This file is no longer where SmartAsset saw it.", symbol: "questionmark.circle.fill", tint: .orange) {
                Button("Show Missing Files") { model.sidebar = .missing }.controlSize(.small)
            }
        } else if !s.volumeOnline {
            notice("Plug in “\(s.volumeName)” to open this file.", symbol: "externaldrive.badge.xmark", tint: .secondary) { EmptyView() }
        } else if s.probeState == .failed {
            notice("SmartAsset couldn’t read this file’s details. It is still in your library.", symbol: "exclamationmark.triangle.fill", tint: .yellow) {
                Button("Try Again") { Task { try? await model.handle?.requeueMedia(assetIds: [s.id]) } }.controlSize(.small)
            }
        } else if s.probeState == .pending {
            notice("Waiting to be indexed.", symbol: "clock", tint: .secondary) { EmptyView() }
        }
    }

    private func notice<Actions: View>(_ text: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(Space.sm)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var organize: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Organize").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LabeledContent("Rating") { StarRating(rating: s.rating) { r in Task { await model.setRating(r, for: [s.id]) } } }
            LabeledContent("Flag") { FlagPicker(flag: s.flag) { f in Task { await model.setFlag(f, for: [s.id]) } } }
            LabeledContent("Label") { LabelPicker(label: s.colorLabel) { c in Task { await model.setColorLabel(c, for: [s.id]) } } }
        }
    }

    @ViewBuilder private var collections: some View {
        if !model.collections.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Collections").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.collections) { c in
                    let member = model.selectedCollectionIDs.contains(c.id)
                    Toggle(c.name, isOn: Binding(get: { member }, set: { on in
                        Task { on ? await model.addToCollection(c.id, ids: [s.id]) : await model.removeFromCollection(c.id, ids: [s.id]) }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var fileSection: some View {
        section("File", [
            ("Folder", detail.folderName),
            ("Drive", s.volumeName),
            ("Modified", date(ms: s.mtime)),
            ("Added", date(ms: s.addedAt)),
            ("Path", detail.path ?? "On “\(s.volumeName)” (not connected)"),
        ])
    }

    private var detailsSection: some View {
        var rows: [(String, String)] = []
        if let ms = detail.captureAt { rows.append(("Captured", date(ms: ms))) }
        if let dims = Format.dimensions(width: s.width, height: s.height) { rows.append(("Dimensions", dims)) }
        if let mp = Format.megapixels(width: s.width, height: s.height), s.kind == .image { rows.append(("Resolution", mp)) }
        if let aspect = s.aspect, aspect != .other { rows.append(("Aspect", aspectLabel(aspect))) }
        if let ms = s.durationMs { rows.append(("Duration", Format.duration(milliseconds: ms))) }
        if let fps = detail.fps { rows.append(("Frame rate", Format.frameRate(fps))) }
        if let codec = detail.codec { rows.append(("Codec", codec)) }
        if let rate = detail.bitrate { rows.append(("Bit rate", String(format: "%.1f Mbps", Double(rate) / 1_000_000))) }
        if let sr = detail.sampleRate { rows.append(("Sample rate", String(format: "%g kHz", Double(sr) / 1000))) }
        if let ch = detail.channels { rows.append(("Channels", ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch)")) }
        if let make = detail.cameraMake { rows.append(("Camera", [make, detail.cameraModel].compactMap { $0 }.filter { !($0 == make && detail.cameraModel?.hasPrefix(make) == true) }.joined(separator: " "))) }
        else if let model = detail.cameraModel { rows.append(("Camera", model)) }
        if let lens = detail.lens { rows.append(("Lens", lens)) }
        switch content {
        case .screenCapture: rows.append(("Content", "Screen capture"))
        case .textDocument: rows.append(("Content", "Mostly text"))
        case .camera, nil: break // a camera is already its own row
        }
        if let lat = detail.gpsLat, let lon = detail.gpsLon { rows.append(("GPS", String(format: "%.4f, %.4f", lat, lon))) }
        return section(s.kind.label, rows)
    }

    private var exifPairs: [(String, String)]? {
        guard let json = detail.exifJson, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        let order = ["ISO", "Aperture", "Shutter speed", "Focal length", "Color profile", "Color model", "Bit depth", "Resolution", "Software"]
        return order.compactMap { key in dict[key].map { (key, $0) } }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                        if row.0 == "Path" {
                            // A path is long and rarely read whole: one line, cut in the middle, all of it in the tooltip.
                            Text(row.1).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(row.1)
                        } else {
                            Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
                if title == "File", detail.path != nil, !s.missing {
                    Button("Show in Finder") { Task { await model.showInFinder([s.id]) } }.controlSize(.small)
                }
            }
        }
    }

    private func aspectLabel(_ a: AspectClass) -> String {
        switch a {
        case .square1x1: "1:1"; case .wide16x9: "16:9"; case .vertical9x16: "9:16"; case .standard4x3: "4:3"
        case .portrait3x4: "3:4"; case .photo3x2: "3:2"; case .portrait2x3: "2:3"; case .landscape5x4: "5:4"
        case .portrait4x5: "4:5"; case .ultrawide21x9: "21:9"; case .other: "Other"
        }
    }

    private func date(ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    private func loadPreview() async {
        guard s.thumbRev > 0, let path = model.handle?.thumbPath(assetId: s.id, rev: s.thumbRev) else { preview = nil; return }
        if let cached = ThumbnailLoader.shared.cached(id: s.id, rev: s.thumbRev, bucket: 512) { preview = cached; return }
        let id = s.id, rev = s.thumbRev
        preview = await withCheckedContinuation { continuation in
            ThumbnailLoader.shared.load(id: id, rev: rev, path: path, bucket: 512) { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - Several files

private struct MultiInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = Array(model.selectedIDs)
        let items = model.selectedSummaries
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("\(ids.count.formatted()) files selected").font(.headline)
                if !items.isEmpty, ids.count <= 500 {
                    Text(Format.fileSize(items.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Organize").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    LabeledContent("Rating") { StarRating(rating: commonRating(items)) { r in Task { await model.setRating(r, for: ids) } } }
                    LabeledContent("Flag") { FlagPicker(flag: commonFlag(items)) { f in Task { await model.setFlag(f, for: ids) } } }
                    LabeledContent("Label") { LabelPicker(label: commonLabel(items)) { c in Task { await model.setColorLabel(c, for: ids) } } }
                }
                HStack {
                    Button("Add Tags…") { model.promptAddTags(to: ids) }
                    Menu("Add to Collection") {
                        ForEach(model.collections) { c in Button(c.name) { Task { await model.addToCollection(c.id, ids: ids) } } }
                        if !model.collections.isEmpty { Divider() }
                        Button("New Collection…") { model.promptNewCollection(adding: ids) }
                    }
                    .fixedSize()
                }
                Button("Show in Finder") { Task { await model.showInFinder(ids) } }.controlSize(.small)
            }
            .padding(Space.lg)
        }
    }

    private func commonRating(_ items: [AssetSummaryDto]) -> UInt8 { Set(items.map(\.rating)).count == 1 ? items.first?.rating ?? 0 : 0 }
    private func commonFlag(_ items: [AssetSummaryDto]) -> Flag { Set(items.map(\.flag)).count == 1 ? items.first?.flag ?? .none : .none }
    private func commonLabel(_ items: [AssetSummaryDto]) -> ColorLabel { Set(items.map(\.colorLabel)).count == 1 ? items.first?.colorLabel ?? .none : .none }
}

// MARK: - Controls

struct StarRating: View {
    let rating: UInt8
    let set: (UInt8) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    // Choosing the current rating again clears it.
                    set(rating == UInt8(star) ? 0 : UInt8(star))
                } label: {
                    Image(systemName: star <= Int(rating) ? "star.fill" : "star")
                        .foregroundStyle(star <= Int(rating) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(star == 1 ? "Rate 1 star" : "Rate \(star) stars")
                .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "None" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(min(5, rating + 1))
            case .decrement: set(rating > 0 ? rating - 1 : 0)
            @unknown default: break
            }
        }
    }
}

struct FlagPicker: View {
    let flag: Flag
    let set: (Flag) -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            toggle(.pick, "flag.fill", "Pick (P)", .green)
            toggle(.reject, "xmark.circle.fill", "Reject (X)", .red)
        }
    }

    private func toggle(_ value: Flag, _ symbol: String, _ help: String, _ tint: Color) -> some View {
        Button { set(flag == value ? .none : value) } label: {
            Label(value == .pick ? "Pick" : "Reject", systemImage: symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(flag == value ? tint : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(value == .pick ? "Pick" : "Reject")
        .accessibilityValue(flag == value ? "On" : "Off")
    }
}

struct LabelPicker: View {
    let label: ColorLabel
    let set: (ColorLabel) -> Void

    var body: some View {
        Menu {
            ForEach([ColorLabel.red, .orange, .yellow, .green, .blue, .purple, .gray], id: \.self) { c in
                Button { set(c) } label: {
                    Label(FilterText.colorName(c), systemImage: label == c ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Color(nsColor: LabelColors.color(c) ?? .gray))
                }
            }
            Divider()
            Button("No Label") { set(.none) }
        } label: {
            HStack(spacing: Space.xs) {
                Circle().fill(label == .none ? Color.clear : Color(nsColor: LabelColors.color(label) ?? .clear)).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.secondary.opacity(label == .none ? 0.6 : 0), lineWidth: 1))
                Text(label == .none ? "None" : FilterText.colorName(label))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a color label")
        .accessibilityLabel("Color label")
        .accessibilityValue(label == .none ? "None" : FilterText.colorName(label))
    }
}

struct TagsEditor: View {
    @Environment(AppModel.self) private var model
    let ids: [Int64]
    let tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Tags").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: Space.xs) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.callout)
                        Button { Task { await model.removeTag(tag, from: ids) } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Remove the tag “\(tag)”")
                            .accessibilityLabel("Remove tag \(tag)")
                    }
                    .padding(.horizontal, Space.sm).padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.14), in: Capsule())
                }
            }
            TextField("Add a tag", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let names = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft = ""
                    Task { await model.addTags(names, to: ids) }
                }
                .help("Type a tag and press Return. Separate several with commas.")
                .accessibilityLabel("Add a tag")
        }
    }
}

struct NotesEditor: View {
    @Environment(AppModel.self) private var model
    let id: Int64
    let initial: String
    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Notes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: text.isEmpty ? 28 : 64, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(Space.xs)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add a note").font(.callout).foregroundStyle(.tertiary)
                            .padding(.horizontal, Space.xs + 5).padding(.vertical, Space.xs + 1)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Notes")
        }
        .onAppear { text = initial; saved = initial }
        // Notes save a moment after you stop typing, and when you select another file.
        .task(id: text) {
            guard text != saved else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { await commit() }
        }
        .onDisappear { Task { await commit() } }
    }

    private func commit() async {
        guard text != saved else { return }
        let value = text
        saved = value
        await model.setNotes(value, for: id)
    }
}

/// Wraps its children onto new lines, for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
