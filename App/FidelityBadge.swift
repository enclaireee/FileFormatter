import FileFormatterCore
import SwiftUI

struct FidelityBadge: View {
    let level: FidelityLevel

    var body: some View {
        Label(level.label, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .help(level.explanation)
    }

    private var color: Color {
        switch level {
        case .lossless: .green
        case .reencode: .orange
        case .lossy: .red
        case .extract: .blue
        case .unsupported: .secondary
        }
    }

    private var symbol: String {
        switch level {
        case .lossless: "checkmark.seal"
        case .reencode: "arrow.triangle.2.circlepath"
        case .lossy: "exclamationmark.triangle"
        case .extract: "scissors"
        case .unsupported: "slash.circle"
        }
    }
}

struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .pending:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .converting:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Converting")
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 1) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                reason(message)
            }
        case .skipped(let message):
            VStack(alignment: .leading, spacing: 1) {
                Text("Skipped")
                    .foregroundStyle(.secondary)
                reason(message)
            }
        }
    }

    private func reason(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
    }
}
