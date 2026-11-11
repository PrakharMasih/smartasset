// A tile opens the Viewer by growing into it: the tile's picture travels from the grid to where the Viewer shows it, then
// the Viewer fades in. The Viewer is its own window, so this is a short-lived panel, not SwiftUI's matched geometry.
// Skipped with Reduce Motion; a Viewer opened any other way (menu, Inspector, list) just appears.
import AppKit
import SwiftUI

/// Where a tile was on screen when it was opened, and the picture it showed.
struct ZoomSource {
    var assetID: Int64
    var screenRect: NSRect
    var image: NSImage
    var openedAt: ContinuousClock.Instant
}

@MainActor
enum ZoomTransition {
    /// Snapshot runs play the zoom four times slower, so a picture can be captured part-way. Never in normal use.
    private static let slow: Double = ProcessInfo.processInfo.environment["APP_SNAPSHOT"] != nil ? 4 : 1

    /// A source older than this belongs to an open that did not make a new window (the file was already open).
    private static let freshFor: Duration = .seconds(1)

    static func take(for assetID: Int64, from model: AppModel) -> ZoomSource? {
        defer { model.pendingZoom = nil }
        guard let zoom = model.pendingZoom, zoom.assetID == assetID, zoom.openedAt.duration(to: .now) < freshFor else { return nil }
        return zoom
    }

    /// Hides `window`, flies the picture into it, and shows it. Everything is restored if anything goes wrong.
    static func run(_ zoom: ZoomSource, into window: NSWindow) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        window.alphaValue = 0
        let slow = Self.slow
        // Let the window settle at its first size before measuring where the picture will land.
        Task { @MainActor in
            await Task.yield()
            let target = landing(for: zoom.image, in: window)
            let panel = NSPanel(contentRect: zoom.screenRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let picture = PictureView(frame: NSRect(origin: .zero, size: zoom.screenRect.size))
            picture.scalesUp = true
            picture.fills = true
            picture.image = zoom.image
            panel.contentView = picture
            panel.orderFront(nil)

            // Whatever happens, the Viewer is shown and the panel is gone soon after the animation should have ended.
            var finished = false
            @MainActor func finish() {
                guard !finished else { return }
                finished = true
                window.alphaValue = 1
                panel.close()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.0 * slow + 0.5))
                finish()
            }
            Task { @MainActor in
                await NSAnimationContext.runAnimationGroup { context in // motion: ok, skipped under Reduce Motion above
                    context.duration = 0.32 * slow
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
                    panel.animator().setFrame(target, display: true)
                }
                await NSAnimationContext.runAnimationGroup { context in // motion: ok, skipped under Reduce Motion above
                    context.duration = 0.14 * slow
                    window.animator().alphaValue = 1
                    panel.animator().alphaValue = 0
                }
                finish()
            }
        }
    }

    /// Where the Viewer will show the picture: the largest rectangle of the picture's shape inside the window's content.
    private static func landing(for image: NSImage, in window: NSWindow) -> NSRect {
        let area = window.convertToScreen(window.contentLayoutRect)
        guard image.size.width > 0, image.size.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Put in the Viewer window's background: when the window opens from a tile, play the transition.
struct ZoomIn: NSViewRepresentable {
    let model: AppModel
    let assetID: Int64

    func makeNSView(context: Context) -> Probe { Probe(model: model, assetID: assetID) }
    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private let model: AppModel
        private let assetID: Int64
        private var played = false

        init(model: AppModel, assetID: Int64) {
            self.model = model
            self.assetID = assetID
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !played, let window, let zoom = ZoomTransition.take(for: assetID, from: model) else { return }
            played = true
            ZoomTransition.run(zoom, into: window)
        }
    }
}
