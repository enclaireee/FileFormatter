import AppKit
import SwiftUI

/// Shared chrome for the Image Tools and PDF Tools sheets, so both read as the
/// same kind of instrument: identity, scope, one preview, one commit action.
struct ToolSheetHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let fileSummary: String
    var fileURL: URL?
    let chooseTitle: String
    var isRunning = false
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            IconTile(systemImage: systemImage, tone: .accent, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Text.pageTitle)
                Text(subtitle)
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let fileURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                            .resizable()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }
                    Text(fileSummary)
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: Theme.Space.md)

            Button(chooseTitle, action: choose)
                .disabled(isRunning)
        }
    }
}

struct ToolSheetFooter: View {
    let fileCount: Int
    let isRunning: Bool
    let canApply: Bool
    var applyTitle = "Apply"
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · originals kept")
                .font(Theme.Text.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Space.md)

            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)

            Button(action: apply) {
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Working…")
                    }
                } else {
                    Text(applyTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply || isRunning)
        }
    }
}

/// The preview well shared by both tool sheets. Fixed height stops the sheet
/// from jumping when the options above it change.
struct ToolPreviewPane<Content: View>: View {
    let caption: String
    private let content: Content

    init(caption: String, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Palette.sunken)
                content
            }
            .frame(height: 300)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline.opacity(0.6))
            }

            Text(caption)
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// A consistent label above free-form fields in the tool sheets.
struct FieldLabel: View {
    let text: String
    var help: String?

    var body: some View {
        Text(text)
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .help(help ?? "")
    }
}
