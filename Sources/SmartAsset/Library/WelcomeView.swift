// First launch (plan H3): the person picks the folders. Nothing is preselected and nothing is scanned beforehand.
import AppKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            VStack(spacing: Space.sm) {
                Text("Find Anything in Your Photos, Videos and Audio").font(.title.weight(.semibold)).multilineTextAlignment(.center)
                Text("Add the folders you want to search. SmartAsset reads your files where they are and never changes them. Everything stays on this Mac.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                Task { await model.chooseFolders() }
            } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus").padding(.horizontal, Space.sm)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("Choose a folder to add (⇧⌘O)")

            VStack(alignment: .leading, spacing: Space.sm) {
                point("magnifyingglass", "Then search by describing what you want, like “people talking to camera”.")
                point("hand.raised", "Only folders you add are indexed. Nothing else on your Mac is touched.")
                point("lock", "No account and no internet needed. Nothing leaves your Mac.")
                point("arrow.triangle.2.circlepath", "You can drag folders onto this window at any time.")
            }
            .padding(Space.lg)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Button("Choose AI Models…") { model.settingsTab = .models; openSettings() }
                .buttonStyle(.link)
                .help("See which models SmartAsset can use for search by meaning")
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gridArea("welcome")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}
