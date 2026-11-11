// One tile of the thumbnail grid, drawn with as few views as possible.
import AppKit
import CoreBridge
import os
import SmartAssetKit

/// Colors for Color Labels (plan O1). Their meaning is the color, so these are fixed; menus and VoiceOver also say the name.
enum LabelColors {
    static func color(_ label: ColorLabel) -> NSColor? {
        switch label {
        case .none: nil
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

/// SF Symbol images are slow to make (font parsing), so each look is made once.
@MainActor
enum SymbolCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) -> NSImage? {
        let key = "\(name)|\(Int(size))|\(weight.rawValue)|\(color.hashValue)"
        if let cached = images[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        images[key] = image
        return image
    }
}

/// Each distinct badge ("0:04", "★★★") is drawn once into an image and then only blitted: measuring and drawing text for
/// every tile on every redraw was the largest cost while scrolling a huge library.
@MainActor
enum BadgeCache {
    private static var capsules: [String: (image: NSImage, size: NSSize)] = [:]
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white,
    ]

    static func capsule(_ text: String) -> (image: NSImage, size: NSSize) {
        if let cached = capsules[text] { return cached }
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 4)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            (text as NSString).draw(at: NSPoint(x: 5, y: 2), withAttributes: attributes)
            return true
        }
        image.cacheMode = .always
        capsules[text] = (image, size)
        return (image, size)
    }

    private static var clusters: [String: (image: NSImage, size: NSSize)] = [:]

    /// One small dark capsule holding the color label, the flag and the status mark (offline, missing, damaged), drawn once
    /// per combination. They sit together at the picture's top right instead of in separate corners.
    static func cluster(label: ColorLabel, flag: Flag, status: String?, statusColor: NSColor) -> (image: NSImage, size: NSSize)? {
        var glyphs: [(name: String, color: NSColor)] = []
        switch flag {
        case .pick: glyphs.append(("flag.fill", .systemGreen))
        case .reject: glyphs.append(("xmark.circle.fill", .systemRed))
        case .none: break
        }
        if let status { glyphs.append((status, statusColor)) }
        let dotColor = LabelColors.color(label)
        guard dotColor != nil || !glyphs.isEmpty else { return nil }
        let key = "\(label)|\(flag)|\(status ?? "")"
        if let cached = clusters[key] { return cached }
        let item: CGFloat = 12, gap: CGFloat = 4, pad: CGFloat = 6
        let count = glyphs.count + (dotColor == nil ? 0 : 1)
        let size = NSSize(width: pad * 2 + item * CGFloat(count) + gap * CGFloat(count - 1), height: 20)
        let drawn = glyphs.compactMap { glyph in SymbolCache.image(glyph.name, size: 11, color: glyph.color).map { ($0, glyph.name) } }
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            var x = pad
            if let dotColor {
                let dot = NSRect(x: x, y: (rect.height - item) / 2, width: item, height: item)
                dotColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.white.withAlphaComponent(0.85).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
                x += item + gap
            }
            for (symbol, _) in drawn {
                symbol.draw(in: NSRect(x: x, y: (rect.height - item) / 2, width: item, height: item))
                x += item + gap
            }
            return true
        }
        image.cacheMode = .always
        clusters[key] = (image, size)
        return (image, size)
    }

    private static var symbolBadges: [String: NSImage] = [:]

    /// A round dark backing with an SF Symbol on it (flag, offline, missing…), drawn once.
    static func symbolBadge(_ name: String, color: NSColor) -> NSImage? {
        let key = "\(name)|\(color.hashValue)"
        if let cached = symbolBadges[key] { return cached }
        guard let symbol = SymbolCache.image(name, size: 12, color: color) else { return nil }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 20, height: 20)).fill()
            symbol.draw(in: NSRect(x: 2, y: 2, width: 16, height: 16))
            return true
        }
        image.cacheMode = .always
        symbolBadges[key] = image
        return image
    }
}

/// Badges drawn over the picture: duration, rating, and one cluster for label, flag and status.
final class TileOverlayView: NSView {
    var summary: AssetSummaryDto? { didSet { needsDisplay = true } }
    /// S2: where a video matched the search (milliseconds); shown instead of its length as "▶ 0:42".
    var moment: Int64? { didSet { if oldValue != moment { needsDisplay = true } } }
    /// The size of the real thumbnail in the cell, when there is one (audio waveforms have no pixel size of their own).
    var imageSize: NSSize? { didSet { if oldValue != imageSize { needsDisplay = true } } }
    /// Ratings show while the pointer is over the tile or the tile is selected.
    var showsRating = false { didSet { if oldValue != showsRating { needsDisplay = true } } }
    /// View ▸ Show Ratings on Thumbnails: ratings stay visible on every tile.
    static var alwaysShowsRating = false
    /// The picture fills the whole tile (square crops), so the badges sit on the tile's corners.
    var fills = true { didSet { if oldValue != fills { needsDisplay = true } } }
    override nonisolated var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the picture itself is drawn inside the cell (aspect-fit, never enlarged). A tile with no picture yet, or a
    /// damaged file, gets a 4:3 area so its badges sit where a picture would be.
    func pictureRect(for s: AssetSummaryDto) -> NSRect {
        if fills { return bounds }
        let natural: NSSize?
        if s.kind != .audio, let w = s.width, let h = s.height, w > 0, h > 0 {
            natural = NSSize(width: CGFloat(w), height: CGFloat(h))
        } else if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            natural = imageSize
        } else {
            natural = nil
        }
        guard let natural else {
            let width = min(bounds.width, bounds.height * 4 / 3)
            let height = width * 3 / 4
            return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
        let scale = min(bounds.width / natural.width, bounds.height / natural.height, 1)
        let size = NSSize(width: natural.width * scale, height: natural.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func status(for s: AssetSummaryDto) -> (name: String, color: NSColor)? {
        if s.missing { return ("questionmark.circle.fill", .systemOrange) }
        if !s.volumeOnline { return ("externaldrive.badge.xmark", .systemGray) }
        if s.probeState == .failed { return ("exclamationmark.triangle.fill", .systemYellow) }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = summary else { return }
        let hasDuration = s.durationMs != nil && s.kind != .image
        let wantsRating = s.rating > 0 && (showsRating || Self.alwaysShowsRating)
        let state = status(for: s)
        let cluster = BadgeCache.cluster(label: s.colorLabel, flag: s.flag, status: state?.name, statusColor: state?.color ?? .clear)
        // Most tiles have nothing to show: draw nothing.
        guard hasDuration || wantsRating || cluster != nil else { return }
        let picture = pictureRect(for: s)
        let inset: CGFloat = 6
        let duration = hasDuration
            ? (moment.map { BadgeCache.capsule("▶ " + Format.duration(milliseconds: $0)) } ?? s.durationMs.map { BadgeCache.capsule(Format.duration(milliseconds: $0)) })
            : nil
        let rating = wantsRating ? BadgeCache.capsule(String(repeating: "★", count: Int(s.rating))) : nil
        // On a narrow picture the two bottom badges would overlap: the rating moves up a row.
        let crowded = (duration?.size.width ?? 0) + (rating?.size.width ?? 0) + inset * 3 > picture.width
        if let duration {
            duration.image.draw(in: NSRect(x: picture.minX + inset, y: picture.maxY - inset + 3 - duration.size.height, width: duration.size.width, height: duration.size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let rating {
            let row: CGFloat = crowded && duration != nil ? 1 : 0
            rating.image.draw(in: NSRect(x: picture.maxX - inset - rating.size.width, y: picture.maxY - inset + 3 - rating.size.height - row * 20, width: rating.size.width, height: rating.size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let cluster {
            cluster.image.draw(in: NSRect(x: picture.maxX - inset - cluster.size.width, y: picture.minY + inset - 1, width: cluster.size.width, height: cluster.size.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The picture in a tile. A layer shows the image, so it can crop to fill a square (the gallery look) or fit inside it.
/// A picture smaller than its tile is never scaled up: it is centered at its own size (plan §12 design rules).
final class PictureView: NSView {
    var image: NSImage? { didSet { updateContents() } }
    /// Crop to fill the tile instead of fitting the whole picture in it.
    var fills = true { didSet { if oldValue != fills { updateContents() } } }
    /// Let a picture smaller than the view grow to fill it. Tiles never do; the zoom into the Viewer does.
    var scalesUp = false { didSet { if oldValue != scalesUp { updateContents() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Radius.xs
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        updateContents()
    }

    private func updateContents() {
        guard let layer else { return }
        guard let image else { layer.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contents = image.layerContents(forContentsScale: scale)
        let smaller = !scalesUp && image.size.width <= bounds.width && image.size.height <= bounds.height
        layer.contentsGravity = smaller ? .center : (fills ? .resizeAspectFill : .resizeAspect)
    }
}

final class AssetTileView: NSView {
    let imageView = PictureView()
    let overlay = TileOverlayView()
    let nameField = NSTextField(labelWithString: "")
    private(set) var summary: AssetSummaryDto?
    private var loadOperation: Operation?
    private var posterImage: NSImage?
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet {
            overlay.showsRating = hovering || isSelectedTile
            // The picture grows 2 pt on every side under the pointer: a quiet lift, instant, so Reduce Motion needs no special case.
            if oldValue != hovering { needsLayout = true }
        }
    }
    /// Supplies the original file for a video, to make its filmstrip. Set by the grid.
    var videoURL: ((Int64) -> URL?)?
    var stripPath: ((Int64, Int64) -> String)?
    var showsName = true { didSet { nameField.isHidden = !showsName; needsLayout = true } }
    /// Crop pictures to fill the tile (View ▸ Crop Thumbnails to Squares), or fit the whole picture in it.
    var fillsSquare = true {
        didSet {
            guard oldValue != fillsSquare else { return }
            imageView.fills = fillsSquare
            overlay.fills = fillsSquare
            needsDisplay = true
        }
    }

    var isSelectedTile = false {
        didSet {
            guard oldValue != isSelectedTile else { return }
            overlay.showsRating = isSelectedTile || hovering
            needsDisplay = true
        }
    }
    var windowIsActive = true { didSet { needsDisplay = true } }

    override nonisolated var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(imageView)
        addSubview(overlay)
        nameField.font = .systemFont(ofSize: 11)
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
        addSubview(nameField)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = showsName ? 20 : 0
        let lift: CGFloat = hovering ? 2 : 0
        let imageRect = NSRect(x: 4 - lift, y: 4 - lift, width: bounds.width - 8 + lift * 2, height: bounds.height - 8 - labelHeight + lift * 2)
        imageView.frame = imageRect
        overlay.frame = imageRect
        nameField.frame = NSRect(x: 2, y: bounds.height - labelHeight - 2, width: bounds.width - 4, height: labelHeight)
    }

    /// Selection is an accent ring around the picture and an accent capsule behind the name, not a fill of the whole cell:
    /// the picture stays clear and the file name stays readable.
    override func draw(_ dirtyRect: NSRect) {
        guard isSelectedTile else { return }
        let accent = windowIsActive ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        accent.setStroke()
        accent.setFill()
        if let s = summary {
            let local = overlay.pictureRect(for: s)
            let picture = local.offsetBy(dx: overlay.frame.minX, dy: overlay.frame.minY)
            let ring = NSBezierPath(roundedRect: picture.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 3
            ring.stroke()
        }
        if showsName {
            let text = nameField.attributedStringValue.size().width
            let width = min(nameField.frame.width, ceil(text) + 14)
            let height: CGFloat = 18
            let capsule = NSRect(x: nameField.frame.midX - width / 2, y: nameField.frame.midY - height / 2, width: width, height: height)
            NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2).fill()
        }
    }

    func configure(_ s: AssetSummaryDto?, path: String?, scale: CGFloat, moment: Int64? = nil) {
        loadOperation?.cancel()
        loadOperation = nil
        endScrub()
        summary = s
        overlay.moment = moment
        overlay.summary = s
        guard let s else {
            imageView.image = nil
            overlay.imageSize = nil
            nameField.stringValue = ""
            alphaValue = 1
            voiceOverSummary.withLock { $0 = nil }
            return
        }
        nameField.stringValue = s.name
        nameField.textColor = isSelectedTile && windowIsActive ? .alternateSelectedControlTextColor : .labelColor
        // Files on a drive that is not connected, or gone from disk, are dimmed but still searchable (plan L4).
        alphaValue = (s.missing || !s.volumeOnline) ? 0.55 : 1
        voiceOverSummary.withLock { $0 = s }

        let bucket = ThumbnailLoader.pixelBucket(forPoints: bounds.width, scale: scale)
        if s.thumbRev > 0, let path {
            if let cached = ThumbnailLoader.shared.cached(id: s.id, rev: s.thumbRev, bucket: bucket) {
                show(cached)
            } else {
                imageView.image = placeholder(for: s)
                overlay.imageSize = nil
                let expectedID = s.id, expectedRev = s.thumbRev
                loadOperation = ThumbnailLoader.shared.load(id: s.id, rev: s.thumbRev, path: path, bucket: bucket) { [weak self] image in
                    guard let self, let current = self.summary, current.id == expectedID, current.thumbRev == expectedRev else { return }
                    if let image { self.show(image) } else { self.show(self.placeholder(for: current)); self.overlay.imageSize = nil }
                }
            }
        } else {
            show(placeholder(for: s))
            overlay.imageSize = nil
        }
    }

    private func show(_ image: NSImage) {
        posterImage = image
        overlay.imageSize = image.size
        if isSelectedTile { needsDisplay = true }
        if !hovering { imageView.image = image }
    }

    private func placeholder(for s: AssetSummaryDto) -> NSImage {
        let name = s.probeState == .failed ? "exclamationmark.triangle" : s.kind.symbol
        // Sizes are rounded so the few placeholder looks are shared by every tile.
        let size = (max(24, bounds.width * 0.3) / 8).rounded() * 8
        return SymbolCache.image(name, size: size, weight: .light, color: .tertiaryLabelColor) ?? NSImage()
    }

    // VoiceOver asks for these from its own thread. The tile keeps a cheap copy of its summary in a lock-protected box and the
    // text is built only when asked, so scrolling past thousands of tiles costs nothing.
    private nonisolated let voiceOverSummary = OSAllocatedUnfairLock<AssetSummaryDto?>(initialState: nil)
    override nonisolated func accessibilityLabel() -> String? {
        voiceOverSummary.withLock { $0 }.map(Self.accessibilityText(for:)) ?? "Loading"
    }
    override nonisolated func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if tooltipTag == nil { tooltipTag = addToolTip(bounds, owner: self, userData: nil) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let tag = tooltipTag { removeToolTip(tag); tooltipTag = addToolTip(NSRect(origin: .zero, size: newSize), owner: self, userData: nil) }
    }

    private var tooltipTag: NSView.ToolTipTag?

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        summary.map(tooltip(for:)) ?? ""
    }

    private func tooltip(for s: AssetSummaryDto) -> String {
        var lines = [s.name]
        if let dims = Format.dimensions(width: s.width, height: s.height) { lines.append(dims) }
        if let ms = s.durationMs { lines.append(Format.duration(milliseconds: ms)) }
        lines.append(Format.fileSize(s.size))
        if s.missing { lines.append("No longer where SmartAsset saw it") }
        else if !s.volumeOnline { lines.append("Plug in “\(s.volumeName)” to open this file") }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func accessibilityText(for s: AssetSummaryDto) -> String {
        var parts = ["\(s.name), \(s.kind.label)"]
        if s.rating > 0 { parts.append("\(s.rating) star\(s.rating == 1 ? "" : "s")") }
        if s.flag == .pick { parts.append("picked") } else if s.flag == .reject { parts.append("rejected") }
        if s.colorLabel != .none { parts.append("\(FilterText.colorName(s.colorLabel)) label") }
        if s.missing { parts.append("missing") } else if !s.volumeOnline { parts.append("drive not connected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Hover-scrub (plan V2)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: imageView.frame, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseMoved(with event: NSEvent) {
        guard hovering, let s = summary, s.kind == .video, s.thumbRev > 0, s.volumeOnline, !s.missing else { return }
        let local = convert(event.locationInWindow, from: nil)
        let fraction = min(0.999, max(0, (local.x - imageView.frame.minX) / max(1, imageView.frame.width)))
        let id = s.id, rev = s.thumbRev
        let frames = FilmstripStore.shared.frames(
            id: id, rev: rev, video: videoURL?(id), stripPath: stripPath?(id, rev) ?? "",
            ready: { [weak self] in self?.scrubIfStillHovering() })
        if let frames, !frames.isEmpty {
            let image = frames[min(frames.count - 1, Int(fraction * Double(frames.count)))]
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    override func mouseExited(with event: NSEvent) { endScrub() }

    private func scrubIfStillHovering() {
        guard hovering, let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let local = convert(point, from: nil)
        guard imageView.frame.contains(local) else { return }
        let fake = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        if let fake { mouseMoved(with: fake) }
    }

    private func endScrub() {
        hovering = false
        if let posterImage { imageView.image = posterImage }
    }
}

final class AssetItem: NSCollectionViewItem {
    var tile: AssetTileView { view as! AssetTileView }

    override func loadView() { view = AssetTileView(frame: .zero) }

    override var isSelected: Bool {
        didSet { tile.isSelectedTile = isSelected; tile.nameField.textColor = isSelected && tile.windowIsActive ? .alternateSelectedControlTextColor : .labelColor }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.configure(nil, path: nil, scale: 2)
    }
}
