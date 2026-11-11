// Drives and folder access: everything macOS-specific that the Rust core leaves to Swift (plan D1).
import AppKit
import CoreBridge
import Foundation

nonisolated enum Volumes {
    private static let keys: Set<URLResourceKey> = [
        .volumeURLKey, .volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey,
    ]

    /// The drive a URL lives on, as the engine wants to know it.
    static func volume(of url: URL) -> MountedVolumeDto? {
        guard let values = try? url.resourceValues(forKeys: keys), let root = values.volume else { return nil }
        return describe(root: root, uuid: values.volumeUUIDString, name: values.volumeName, internal: values.volumeIsInternal)
    }

    /// Every drive that is connected right now.
    static func mounted() -> [MountedVolumeDto] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { root in
            let values = try? root.resourceValues(forKeys: keys)
            return describe(root: root, uuid: values?.volumeUUIDString, name: values?.volumeName, internal: values?.volumeIsInternal)
        }
    }

    private static func describe(root: URL, uuid: String?, name: String?, internal isInternal: Bool?) -> MountedVolumeDto {
        // Some network shares have no UUID: their mount path stands in, which is stable for that share.
        MountedVolumeDto(uuid: uuid ?? "path:\(root.path)", name: name ?? root.lastPathComponent,
                         mountPath: root.path, isInternal: isInternal ?? (root.path == "/"))
    }
}

/// Keeps security-scoped access to added folders alive for the whole run (plan L1b).
final class FolderAccess {
    private var open: [Int64: URL] = [:]

    /// A bookmark for a folder the person just picked in the folder picker.
    func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func remember(folderID: Int64, url: URL) {
        open[folderID]?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        open[folderID] = url
    }

    func forget(folderID: Int64) {
        open.removeValue(forKey: folderID)?.stopAccessingSecurityScopedResource()
    }

    struct Resolved {
        var url: URL
        /// macOS made a newer bookmark; store it.
        var refreshedBookmark: Data?
    }

    /// Re-opens access for a stored bookmark. Returns nil when it can no longer be resolved.
    func resolve(folderID: Int64, bookmark: Data) -> Resolved? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        remember(folderID: folderID, url: url)
        let fresh = stale ? makeBookmark(for: url) : nil
        return Resolved(url: url, refreshedBookmark: fresh)
    }

    func stopAll() {
        for url in open.values { url.stopAccessingSecurityScopedResource() }
        open.removeAll()
    }
}

/// Reports plugged-in and removed drives to the engine (plan L4).
final class VolumeMonitor {
    private var tokens: [NSObjectProtocol] = []

    func start(mounted: @escaping @MainActor (MountedVolumeDto) -> Void, unmounted: @escaping @MainActor (String) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL, let volume = Volumes.volume(of: url) else { return }
            MainActor.assumeIsolated { mounted(volume) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            // The drive is already gone, so its UUID cannot be read: match by the mount path we stored.
            let path = url.path
            MainActor.assumeIsolated { unmounted(path) }
        })
    }

    func stop() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
    }
}
