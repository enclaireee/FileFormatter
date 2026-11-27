import AppKit
import FileFormatterCore
import SwiftUI

struct EmptyStateView: View {
    @Bindable var model: AppModel
    var isDropTargeted = false
    @State private var canPaste = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Everyday outcomes shown upfront so users can start in 1 click without opening a dropdown.
    private var starters: [Preset] {
        ["web-images", "remove-bg", "compress-pdf", "images-pdf", "video-mp4", "office-markdown"].compactMap { id in
            Preset.builtIn.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: Theme.Space.md)

            dropCard

            VStack(spacing: Theme.Space.sm) {
                Text(model.activePreset.map { "Selected recipe: \($0.name) — now drop your files above" }
                     ?? "Or pick a quick recipe first")
                    .font(Theme.Text.caption.weight(.medium))
                    .foregroundStyle(model.activePreset != nil ? Theme.Palette.accent : .secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 150, maximum: 210), spacing: 8),
                        GridItem(.flexible(minimum: 150, maximum: 210), spacing: 8),
                        GridItem(.flexible(minimum: 150, maximum: 210), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(starters) { preset in
                        presetCard(preset)
                    }
                }
                .frame(maxWidth: 620)
            }

            Spacer(minLength: Theme.Space.md)

            HStack(spacing: 14) {
                Label("100% On-device", systemImage: "lock.shield")
                Text("·")
                Label("Originals never overwritten", systemImage: "arrow.uturn.backward.circle")
                Text("·")
                Text("Menu bar shortcut: ⌥⌘F")
            }
            .font(Theme.Text.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xl)
        .onAppear {
            canPaste = ClipboardImport.hasPasteableContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            canPaste = ClipboardImport.hasPasteableContent()
        }
    }

    private var dropCard: some View {
        VStack(spacing: Theme.Space.lg) {
            IconTile(
                systemImage: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc",
                tone: isDropTargeted ? .accent : .neutral,
                size: 64
            )
            .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 6) {
                Text(isDropTargeted ? "Release to add files" : "Drop files or folders here")
                    .font(.title2.weight(.semibold))
                Text("Convert images, PDFs, Office docs, data, audio, and video—preview every output before running.")
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Choose Files…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.showFolderImporter = true
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if canPaste {
                    Button {
                        model.pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Paste copied files or screenshot (⌘V)")
                }
            }
        }
        .padding(.vertical, 36)
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: 620)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(isDropTargeted ? Theme.Palette.accent.opacity(0.08) : Theme.Palette.surface.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Theme.Palette.hairline.opacity(0.75)),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [7, 5] : [6, 6])
                )
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isDropTargeted)
    }

    private func presetCard(_ preset: Preset) -> some View {
        let selected = model.activePreset?.id == preset.id
        return Button {
            model.apply(preset)
        } label: {
            HStack(spacing: 9) {
                IconTile(
                    systemImage: preset.systemImage,
                    tone: selected ? .accent : .neutral,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(preset.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    if !preset.subtitle.isEmpty {
                        Text(preset.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? Theme.Palette.accent.opacity(0.11) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.Palette.accent.opacity(0.45) : Theme.Palette.hairline.opacity(0.45),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Apply \(preset.name) recipe")
    }
}
