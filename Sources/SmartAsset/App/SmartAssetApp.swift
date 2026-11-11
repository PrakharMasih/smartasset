// SmartAsset
//   SmartAsset                         the app
//   APP_DATA=<dir> SmartAsset          use another library folder (tests, snapshots)
//   APP_SNAPSHOT=<dir> SmartAsset      save PNGs of every screen in light and dark, then quit (tools/snap.sh)
//   APP_DEMO=1 SmartAsset              fill an empty library with sample media (only with APP_DATA in /tmp)
//   APP_ACCENT=<id> SmartAsset         run with another accent from Theme.all
//   APP_GRID=1 SmartAsset              draw the 4 pt grid and layout probes over the window
import AppKit
import CoreBridge
import SmartAssetKit
import SwiftUI

@main
struct SmartAssetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @ObservedObject private var menu = MenuState.shared

    var body: some Scene {
        Window("SmartAsset", id: "main") {
            MainView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    delegate.model = model
                    _ = Bench.started
                    await model.launch()
                    await SelfTest.runIfRequested(model: model)
                    await Snapshot.runIfRequested(model: model)
                    await Bench.runIfRequested(model: model)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model, selectionCount: menu.selectionCount, onDuplicates: menu.onDuplicates, tickedCopies: menu.tickedCopies, recentSearchCount: menu.recentSearches, meaningReady: menu.meaningReady) }

        WindowGroup("Viewer", id: "viewer", for: Int64.self) { $assetID in
            if let assetID {
                ViewerWindow(assetID: assetID)
                    .environment(model)
                    .themed()
            }
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders dropped on the Dock icon or opened with SmartAsset from Finder are added to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter(\.hasDirectoryPath)
        guard !folders.isEmpty, let model else { return }
        Task { await model.addFolders(folders) }
    }

    /// Quit waits for the engine to finish its current write, so the next launch never thinks it crashed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Also while launching: the search model may already be loading on the GPU.
        guard let model, !model.isShutDown else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
