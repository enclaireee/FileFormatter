import FileFormatterCore
import SwiftUI

struct EmptyStateView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 54, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Drop files to convert")
                    .font(.title2.weight(.semibold))
                Text("See every change before it happens. Originals stay safe.")
                    .foregroundStyle(.secondary)
            }

            Button("Choose Files…") {
                model.showImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            HStack(spacing: 6) {
                ForEach(["JPEG", "PNG", "HEIC", "AVIF", "WebP", "PDF", "CSV", "JSON"], id: \.self) { format in
                    Text(format)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }

            Text("No uploads. Nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
