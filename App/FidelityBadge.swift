import FileFormatterCore
import SwiftUI

struct FidelityBadge: View {
    let level: FidelityLevel

    var body: some View {
        Badge(text: level.label, systemImage: symbol, tone: tone)
            .help(level.explanation)
    }

    private var tone: Theme.Tone {
        switch level {
        case .lossless: .success
        case .reencode: .warning
        case .lossy: .danger
        case .extract: .info
        case .unsupported: .neutral
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
                .foregroundStyle(Theme.Palette.success)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 1) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(Theme.Palette.danger)
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
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
    }
}
