// The Viewer (plan V4): one file large. Images zoom, video plays with frame stepping, audio shows its waveform.
import AVFoundation
import AVKit
import AppKit
import CoreBridge
import ImageIO
import SmartAssetKit
import SwiftUI
import Workers

@Observable
final class ViewerModel {
    private(set) var detail: AssetDetailDto?
    private(set) var url: URL?
    private(set) var position: Int?
    private(set) var failure: String?
    /// For a video opened from a search: the moment that looks most like the words (S2), in seconds. Otherwise 0.
    private(set) var startSeconds: Double = 0
    let app: AppModel
    private var token = 0

    init(app: AppModel) { self.app = app }

    var total: Int { app.resultCount }

    func show(_ id: Int64) async {
        token += 1
        let mine = token
        guard let handle = app.handle else { return }
        do {
            let d = try await handle.assetDetail(assetId: id)
            guard mine == token else { return }
            detail = d
            failure = nil
            url = d.path.map { URL(fileURLWithPath: $0) }
            position = app.results?.indexOf(id: id).map { Int($0) }
            startSeconds = 0
            if let chosen = app.viewerStart, chosen.id == id {
                // A moment picked in the Inspector wins, once.
                app.viewerStart = nil
                startSeconds = chosen.seconds
            } else if d.summary.kind == .video, let moment = await app.explainMatch(id)?.meaning?.momentMs, mine == token {
                startSeconds = Double(moment) / 1000
            }
            if url == nil { failure = d.summary.missing ? "This file is no longer where SmartAsset saw it." : "Plug in “\(d.summary.volumeName)” to open this file." }
            else if let url, !FileManager.default.fileExists(atPath: url.path) { self.url = nil; failure = "This file is no longer where SmartAsset saw it." }
        } catch {
            failure = error.userMessage
        }
    }

    /// Steps through the current results, with wrap-around at neither end.
    func step(_ delta: Int) async {
        guard let position, let results = app.results else { return }
        let next = position + delta
        guard next >= 0, next < Int(results.count()), let id = results.idAt(index: UInt64(next)) else { return }
        await show(id)
        app.selectedIDs = [id]
    }

    func rate(_ stars: UInt8) async {
        guard let id = detail?.summary.id else { return }
        await app.setRating(stars, for: [id])
        await show(id)
    }

    func flag(_ flag: Flag) async {
        guard let id = detail?.summary.id else { return }
        await app.setFlag(flag, for: [id])
        await show(id)
    }
}

struct ViewerWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    let assetID: Int64
    @State private var viewer: ViewerModel?

    var body: some View {
        Group {
            if let viewer { ViewerContent(viewer: viewer) } else { ProgressView() }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: assetID) {
            let model = viewer ?? ViewerModel(app: app)
            viewer = model
            await model.show(assetID)
        }
        .onExitCommand { dismissWindow(id: "viewer") }
        .noInitialFocus()
        .background(ZoomIn(model: app, assetID: assetID))
    }
}

private struct ViewerContent: View {
    let viewer: ViewerModel
    @State private var zoom = ImageZoom()

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            if let detail = viewer.detail, let url = viewer.url {
                switch detail.summary.kind {
                case .image: ImageViewer(url: url, zoom: zoom).id(detail.summary.id)
                case .video: VideoViewer(url: url, start: viewer.startSeconds).id(detail.summary.id)
                case .audio: AudioViewer(url: url, name: detail.summary.name).id(detail.summary.id)
                }
            } else if let failure = viewer.failure {
                ContentUnavailableView("Can’t Open This File", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(viewer.detail?.summary.name ?? "Viewer")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { Task { await viewer.step(-1) } } label: { Label("Previous", systemImage: "chevron.left") }
                    .help("Show the previous file (←)").keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled((viewer.position ?? 0) <= 0)
                Button { Task { await viewer.step(1) } } label: { Label("Next", systemImage: "chevron.right") }
                    .help("Show the next file (→)").keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled((viewer.position ?? 0) >= viewer.total - 1)
            }
            if viewer.detail?.summary.kind == .image {
                ToolbarItemGroup {
                    Button { zoom.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Fit the image in the window (⌘0)").keyboardShortcut("0")
                    Button { zoom.actualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                        .help("Show at 100% (⌘1)").keyboardShortcut("1")
                    Button { zoom.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                        .help("Zoom in (⌘+)").keyboardShortcut("+")
                    Button { zoom.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .help("Zoom out (⌘−)").keyboardShortcut("-")
                }
            }
            ToolbarItemGroup {
                if let detail = viewer.detail {
                    FlagPicker(flag: detail.summary.flag) { f in Task { await viewer.flag(f) } }
                    StarRating(rating: detail.summary.rating) { r in Task { await viewer.rate(r) } }
                }
            }
        }
    }

    private var subtitle: String {
        guard let position = viewer.position else { return "" }
        let place = "\(position + 1) of \(viewer.total.formatted())"
        // Opened from the Search page, the files are the matches: say so.
        guard viewer.app.sidebar == .search else { return place }
        switch viewer.app.searchReadiness {
        case .ready, .preparing: return place + " Best Matches"
        case .loading, .wordsOnly: return place + " Matches"
        }
    }
}

// MARK: - Image

@MainActor
final class ImageZoom {
    weak var scroll: NSScrollView?
    func fit() {
        guard let scroll, let doc = scroll.documentView else { return }
        scroll.magnify(toFit: doc.bounds)
    }
    func actualSize() { scroll?.magnification = 1 }
    func zoomIn() { scroll.map { $0.magnification = min($0.maxMagnification, $0.magnification * 1.25) } }
    func zoomOut() { scroll.map { $0.magnification = max($0.minMagnification, $0.magnification / 1.25) } }
}

private struct ImageViewer: NSViewRepresentable {
    let url: URL
    let zoom: ImageZoom

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        scroll.documentView = imageView
        zoom.scroll = scroll
        let url = url
        Task.detached(priority: .userInitiated) {
            let image = Self.load(url)
            await MainActor.run {
                guard let image else { return }
                imageView.image = image
                imageView.frame = NSRect(origin: .zero, size: image.size)
                scroll.magnify(toFit: imageView.bounds)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { zoom.scroll = scroll }

    /// Decodes at full size up to a cap that keeps huge RAW files from using gigabytes.
    nonisolated private static func load(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8192,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Video

private struct VideoViewer: NSViewRepresentable {
    let url: URL
    /// Where to begin, in seconds (the moment a search matched). 0 plays from the start.
    var start: Double = 0

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        // Frame stepping buttons are built in (plan V4).
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: url)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Audio

private struct AudioViewer: View {
    let url: URL
    let name: String
    @State private var peaks: [Float] = []
    @State private var player: AVPlayer?
    @State private var progress = 0.0
    @State private var playing = false
    @State private var duration = 0.0
    @State private var timeToken: Any?

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            waveform
                .frame(height: 160)
                .padding(.horizontal, Space.xl)
            HStack(spacing: Space.lg) {
                Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 28, height: 28) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(playing ? "Pause (Space)" : "Play (Space)")
                Text("\(Format.duration(milliseconds: Int64(progress * duration * 1000))) / \(Format.duration(milliseconds: Int64(duration * 1000)))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(Space.xl)
        .task { await prepare() }
        .onDisappear { stop() }
    }

    private var waveform: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                let top = max(peaks.max() ?? 0, 0.05)
                for (i, p) in peaks.enumerated() {
                    let h = max(2, CGFloat(p / top) * size.height * 0.95)
                    let rect = CGRect(x: CGFloat(i) * barWidth, y: (size.height - h) / 2, width: max(1, barWidth - 1), height: h)
                    let played = Double(i) / Double(peaks.count) < progress
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? Palette.accent : Color.secondary.opacity(0.75)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in seek(to: min(1, max(0, value.location.x / proxy.size.width))) })
        }
        .accessibilityLabel("Waveform of \(name)")
        .accessibilityValue("\(Int(progress * 100)) percent played")
    }

    private func prepare() async {
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                guard duration > 0 else { return }
                progress = min(1, time.seconds / duration)
                if progress >= 0.999 { playing = false }
            }
        }
        peaks = (try? await Waveform.peaks(of: url, buckets: 200)) ?? []
    }

    private func toggle() {
        guard let player else { return }
        if playing { player.pause() } else {
            if progress >= 0.999 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    private func seek(to fraction: Double) {
        progress = fraction
        player?.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stop() {
        player?.pause()
        if let timeToken { player?.removeTimeObserver(timeToken) }
        timeToken = nil
        player = nil
    }
}
