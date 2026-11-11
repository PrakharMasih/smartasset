// Spacebar preview (plan V3): the system Quick Look panel, with arrow keys stepping through nearby files.
import AppKit
import CoreBridge
import QuickLookUI

@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    /// How many neighbours on each side of a single selected file can be stepped to.
    private static let reach = 60

    func show(model: AppModel, ids: [Int64]) async {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.close(); return }
        guard let handle = model.handle else { return }

        // One file selected: offer its neighbours so the arrow keys keep going. Several: preview just those.
        var window = ids
        var start = 0
        if ids.count == 1, let results = model.results, let index = results.indexOf(id: ids[0]) {
            let lo = max(0, Int(index) - Self.reach)
            window = results.idsIn(offset: UInt64(lo), limit: UInt64(Self.reach * 2 + 1))
            start = Int(index) - lo
        }
        guard let paths = try? await handle.paths(assetIds: window) else { return }
        var list: [URL] = []
        var current = 0
        for (offset, entry) in paths.enumerated() {
            guard let path = entry.path else { continue }
            if offset == start { current = list.count }
            list.append(URL(fileURLWithPath: path))
        }
        guard !list.isEmpty else {
            model.inform("Plug in the drive to preview these files.")
            return
        }
        // If the chosen file itself is offline, start at the nearest one that is not.
        urls = list
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(current, list.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    // AppKit calls these on the main thread.
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        index >= 0 && index < urls.count ? urls[index] as NSURL : nil
    }
}
