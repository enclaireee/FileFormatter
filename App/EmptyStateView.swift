import FileFormatterCore
import SwiftUI

struct EmptyStateView: View {
    @Bindable var model: AppModel
    var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A few common starting points; the full list is in the inspector's Preset picker.
    private var starters: [Preset] {
        ["web-images", "images-pdf", "office-markdown", "video-mp4"].compactMap { id in
            Preset.builtIn.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            Spacer(minLength: Theme.Space.lg)

            dropCard

            VStack(spacing: Theme.Space.sm) {
                Text("START FROM A PRESET")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: Theme.Space.sm) {
                    ForEach(starters) { preset in
                        presetChip(preset)
                    }
                }
                .frame(maxWidth: 540)

                Text(model.activePreset.map { "\($0.name) is ready. Drop files to use it." }
                     ?? "Or drop files and choose formats afterwards.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Space.md)

            VStack(spacing: 4) {
                Label("On-device only. Your files never leave this Mac.", systemImage: "lock.shield")
                Text("You can also drop files on the menu bar icon or use Finder Quick Actions.")
            }
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xl)
    }

    private var dropCard: some View {
        VStack(spacing: Theme.Space.lg) {
            IconTile(
                systemImage: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc",
                tone: isDropTargeted ? .accent : .neutral,
                size: 66
            )
            .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 6) {
                Text(isDropTargeted ? "Drop to add" : "Drop files to convert")
                    .font(.title2.weight(.semibold))
                Text("Images, PDFs, documents, audio or video. You'll see every result before anything is written.")
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.md) {
                Button("Choose Files…") {
                    model.showImporter = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("or press ⌘O")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 38)
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(isDropTargeted ? Theme.Palette.accent.opacity(0.07) : Theme.Palette.surface.opacity(0.55))
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

    private func presetChip(_ preset: Preset) -> some View {
        let selected = model.activePreset?.id == preset.id
        return Button {
            model.apply(preset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.caption)
                Text(preset.name)
                    .lineLimit(1)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.callout)
            .foregroundStyle(selected ? Theme.Palette.accent : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                selected ? Theme.Palette.accent.opacity(0.12) : Color.primary.opacity(0.04),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? Theme.Palette.accent.opacity(0.35) : Theme.Palette.hairline.opacity(0.5),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help("Use \(preset.name) for the next files")
    }
}
