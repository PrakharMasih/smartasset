// The confirmation screen of duplicate cleanup (plan A3): every file that will move, with size, modification date,
// full location and match, and the file that stays. Nothing moves until Move to Trash is pressed.
import CoreBridge
import SmartAssetKit
import SwiftUI

struct CleanupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let review = model.cleanupReview {
            content(review)
        }
    }

    private func content(_ review: CleanupReview) -> some View {
        let remove = review.remove
        let keep = review.keep
        let exact = review.allExact
        return VStack(alignment: .leading, spacing: Space.md) {
            Text(DuplicateText.reviewTitle(count: remove.count)).font(.headline)
            Text("These files move to the Trash, so you can put them back from there. \(Format.fileSize(review.bytes)) will be freed.")
                .font(.callout).foregroundStyle(.secondary)

            fileTable(remove, exact: exact, label: "Files that move to the Trash")
                .frame(height: min(320, CGFloat(remove.count) * 28 + 40))

            Text(keep.count == 1 ? "This file stays" : "These files stay").font(.subheadline.weight(.medium))
            fileTable(keep, exact: exact, label: "Files that stay")
                .frame(height: min(140, CGFloat(keep.count) * 28 + 40))

            Text(DuplicateText.mergeNote).font(.callout).foregroundStyle(.secondary)
            if !review.skipped.isEmpty {
                Label("\(review.skipped.count) \(review.skipped.count == 1 ? "group was" : "groups were") left out: \(review.skipped[0])",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if case .refused(let why) = review.phase {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if review.phase == .working { ProgressView().controlSize(.small) }
                Spacer()
                if case .refused = review.phase {
                    Button("Close") { close(review) }.keyboardShortcut(.cancelAction).keyboardShortcut(.defaultAction)
                } else {
                    // Cancel is the default so a stray Return can never move a file.
                    Button("Cancel", role: .cancel) { close(review) }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .disabled(review.phase == .working)
                    Button("Move to Trash", role: .destructive) { Task { await model.confirmCleanup() } }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(review.phase == .working)
                        .help("Move these files to the Trash (⌘⌫)")
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 880)
        .interactiveDismissDisabled(review.phase == .working)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DuplicateText.reviewTitle(count: remove.count))
    }

    private func close(_ review: CleanupReview) {
        if case .refused = review.phase {
            // The review is spent; drop it and show what is true now.
            model.cleanupReview = nil
            model.refreshDuplicates()
        } else {
            model.cancelCleanupReview()
        }
    }

    private func fileTable(_ files: [CleanupFileDto], exact: Bool, label: String) -> some View {
        Table(files) {
            TableColumn("Name") { f in Text(f.name).lineLimit(1).truncationMode(.middle).help(f.name) }
                .width(min: 120, ideal: 160)
            TableColumn("Size") { f in Text(Format.fileSize(f.size)).monospacedDigit() }
                .width(70)
            TableColumn("Modified") { f in
                Text(Date(timeIntervalSince1970: Double(f.modifiedMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            .width(min: 160, ideal: 176)
            TableColumn("Match") { f in Text(DuplicateText.match(percent: f.matchPercent, exact: exact)) }
                .width(80)
            TableColumn("Location") { f in
                // The name has its own column: the location is the folder, with the full path in the tooltip.
                Text((URL(fileURLWithPath: f.path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).help(f.path)
            }
            .width(min: 200, ideal: 260)
        }
        .accessibilityLabel(label)
    }
}
