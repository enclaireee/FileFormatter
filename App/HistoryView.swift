import AppKit
import FileFormatterCore
import SwiftUI

struct HistoryView: View {
    @State private var runs: [RunSummary] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading history…")
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed conversions and their undo history appear here.")
                )
            } else {
                List(runs) { run in
                    row(run)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            runs = Array(await RunJournal.shared.all().reversed())
            isLoading = false
        }
    }

    private func row(_ run: RunSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .foregroundStyle(run.undone ? Color.secondary : Color.green)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(run.target)
                        .font(.headline)
                    if run.undone {
                        Text("Undone")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(run.converted) converted · \(run.skipped) skipped · \(run.failed) failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !run.outputs.isEmpty {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(run.outputs)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
