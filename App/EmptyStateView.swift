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
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 48, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(spacing: 6) {
                    Text(isDropTargeted ? "Drop to add" : "Drop files or folders here")
                        .font(.title2.weight(.semibold))
                    Text("You'll see what each file becomes before anything is converted. Originals are never changed.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                Button("Choose Files…") {
                    model.showImporter = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(36)
            .frame(maxWidth: 520)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
            }
            .animation(reduceMotion ? nil : .default, value: isDropTargeted)

            VStack(spacing: 10) {
                Text("Start from a preset")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(starters) { preset in
                        Toggle(isOn: Binding(
                            get: { model.activePreset?.id == preset.id },
                            set: { if $0 { model.apply(preset) } }
                        )) {
                            Label(preset.name, systemImage: preset.systemImage)
                        }
                        .toggleStyle(.button)
                        .fixedSize()
                    }
                }
                .frame(maxWidth: 520)
                Text(model.activePreset.map { "\($0.name) is set. Drop files to use it." } ?? "Or just drop files; you can choose formats after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Text("Everything stays on this Mac. You can also drop files on the menu bar icon or right-click them in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
