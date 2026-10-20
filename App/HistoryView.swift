import AppKit
import FileFormatterCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var runs: [RunSummary] = []
    @State private var isLoading = true
    @State private var pendingUndo: RunSummary?
    @State private var message: Message?

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let tone: Theme.Tone
    }

    private var convertedTotal: Int {
        runs.reduce(0) { $0 + $1.converted }
    }

    private var subtitle: String {
        if isLoading { return "Loading runs…" }
        guard !runs.isEmpty else { return "Completed conversions and renames appear here, with an undo option." }
        return "\(runs.count) run\(runs.count == 1 ? "" : "s") · \(convertedTotal) file\(convertedTotal == 1 ? "" : "s") converted"
    }

    private var days: [(date: Date, runs: [RunSummary])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("History", subtitle: subtitle)

            if let message {
                statusBanner(message)
            }

            content
        }
        .navigationTitle("History")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await reload()
        }
        .confirmationDialog(
            pendingUndo?.renames != nil ? "Undo this rename?" : "Undo this run?",
            isPresented: Binding(
                get: { pendingUndo != nil },
                set: { if !$0 { pendingUndo = nil } }
            )
        ) {
            Button(
                pendingUndo?.renames != nil ? "Restore Previous Names" : "Move New Files to Trash",
                role: .destructive
            ) {
                guard let run = pendingUndo else { return }
                pendingUndo = nil
                Task { await undo(run) }
            }
            Button("Cancel", role: .cancel) { pendingUndo = nil }
        } message: {
            Text(pendingUndo?.renames != nil
                 ? "Every file returns to its previous name."
                 : "Only the files created by this run move to the Trash. Your originals aren't touched.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: Theme.Space.md) {
                ProgressView()
                Text("Loading history…")
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if runs.isEmpty {
            EmptyStatePanel(
                systemImage: "clock.arrow.circlepath",
                title: "No runs yet",
                message: "Completed conversions and renames appear here. You can undo a run or reveal its files at any time."
            )
        } else {
            List {
                ForEach(days, id: \.date) { day in
                    Section(dayTitle(day.date)) {
                        ForEach(day.runs) { run in
                            row(run)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ run: RunSummary) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            IconTile(systemImage: icon(for: run), tone: tone(for: run), size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.sm) {
                    Text(run.target)
                        .font(.headline)
                        .lineLimit(1)
                    if run.undone {
                        Badge(text: "Undone", systemImage: "arrow.uturn.backward", tone: .neutral)
                    }
                }

                Text(run.date.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    if run.converted > 0 {
                        Badge(text: "\(run.converted) converted", systemImage: "checkmark", tone: .success)
                    }
                    if run.skipped > 0 {
                        Badge(text: "\(run.skipped) skipped", tone: .warning)
                    }
                    if run.failed > 0 {
                        Badge(text: "\(run.failed) failed", systemImage: "xmark", tone: .danger)
                    }
                    if run.outputBytes > 0 {
                        Text(ByteCount.string(run.outputBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: Theme.Space.sm)

            HStack(spacing: Theme.Space.sm) {
                if !run.outputs.isEmpty {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting(run.outputs)
                    }
                    .controlSize(.small)
                    .disabled(run.undone)
                }

                if !run.undone, run.converted > 0 {
                    Button(run.renames != nil ? "Undo Rename" : "Undo…") {
                        pendingUndo = run
                    }
                    .controlSize(.small)
                    .help(run.renames != nil ? "Restore the previous file names" : "Move the new files to the Trash")
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func statusBanner(_ message: Message) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: message.tone == .danger ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.color(for: message.tone))
                .accessibilityHidden(true)
            Text(message.text)
                .font(Theme.Text.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            Button {
                self.message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background(Theme.Palette.fill(for: message.tone), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func icon(for run: RunSummary) -> String {
        if run.renames != nil { return "character.cursor.ibeam" }
        let target = run.target.lowercased()
        if target.contains("pdf") { return "doc.richtext" }
        if target.contains("tool") || target.contains("rotate") || target.contains("crop") { return "wrench.and.screwdriver" }
        if target.contains("image") || target.contains("web") || target.contains("photo") { return "photo" }
        if target.contains("video") || target.contains("mp4") { return "film" }
        if target.contains("audio") || target.contains("mp3") || target.contains("flac") { return "waveform" }
        if target.contains("rename") { return "character.cursor.ibeam" }
        return "arrow.triangle.2.circlepath"
    }

    private func tone(for run: RunSummary) -> Theme.Tone {
        if run.undone { return .neutral }
        if run.failed > 0 { return .warning }
        return .success
    }

    private func undo(_ run: RunSummary) async {
        if run.renames != nil {
            await model.undoRename(run)
        } else {
            await model.undoRun(run)
        }
        await reload()
        message = Message(
            text: run.renames != nil
                ? "The previous names were restored."
                : "The run was undone. New files moved to the Trash; originals weren't touched.",
            tone: .info
        )
    }

    private func reload() async {
        runs = Array(await RunJournal.shared.all().reversed())
        isLoading = false
    }
}
