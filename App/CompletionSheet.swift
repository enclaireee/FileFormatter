import FileFormatterCore
import SwiftUI

struct CompletionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var summary: RunSummary? { model.lastSummary }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(success ? .green : .orange)

            Text(success ? "Conversion complete" : "Nothing was converted")
                .font(.title2.weight(.semibold))

            if let summary {
                HStack(spacing: 26) {
                    stat("Converted", summary.converted)
                    stat("Skipped", summary.skipped)
                    stat("Failed", summary.failed)
                }

                if summary.converted > 0 {
                    Text(sizeLine(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if summary.failed > 0 {
                    failureList
                }

                Text("Undo moves generated files to the Trash. Your originals are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack {
                Button("Reveal in Finder") {
                    model.revealLastOutputs()
                }
                .disabled(summary?.outputs.isEmpty ?? true)

                Button("Undo Run") {
                    Task {
                        await model.undoLastRun()
                        dismiss()
                    }
                }
                .disabled(summary?.undone == true || summary?.outputs.isEmpty ?? true)
                .help("Move the generated files to the Trash")

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private var success: Bool {
        (summary?.converted ?? 0) > 0
    }

    private func sizeLine(_ summary: RunSummary) -> String {
        if summary.bytesSaved > 0 {
            return "\(ByteCount.string(UInt64(summary.bytesSaved))) saved"
        }
        return "\(ByteCount.string(summary.outputBytes)) written"
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(failedItems.prefix(3)) { item in
                if case .failed(let message) = item.status {
                    Text("\(item.displayName): \(message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if failedItems.count > 3 {
                Text("and \(failedItems.count - 3) more…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var failedItems: [ConversionItem] {
        model.items.filter { item in
            if case .failed = item.status { true } else { false }
        }
    }
}
