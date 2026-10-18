import FileFormatterCore
import SwiftUI

struct RenameSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("renamePattern") private var pattern = "{name}-{n:2}"
    @State private var start = 1
    @State private var done: RunSummary?
    @State private var error: String?

    private var sources: [URL] {
        var seen = Set<String>()
        return model.items.map(\.sourceURL).filter { seen.insert($0.path).inserted }
    }

    private var preview: [Renamer.Rename] {
        Renamer.preview(sources, pattern: pattern, start: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(sources.count) Files")
                .font(.title2.weight(.semibold))

            if let done {
                finished(done)
            } else {
                form
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .onChange(of: pattern) { error = nil }
        .onChange(of: start) { error = nil }
    }

    private var form: some View {
        let renames = preview
        let problems = renames.filter { $0.problem != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Pattern", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Stepper("Start at \(start)", value: $start, in: 0...99_999)
                    .fixedSize()
            }
            Text("Tokens: {name}  {n}  {n:3} (padded)  {date}  {ext}. The extension is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(renames) { rename in
                HStack {
                    Text(rename.from.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(rename.to.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let problem = rename.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help(problem)
                    }
                }
            }
            .listStyle(.bordered)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if problems > 0 {
                    Label("\(problems) name(s) need fixing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { apply(renames) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problems > 0 || renames.isEmpty)
            }
        }
    }

    private func finished(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Renamed \(summary.converted) file(s).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Undo puts every name back the way it was.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Undo Rename") {
                    Task {
                        await model.undoRename(summary)
                        dismiss()
                    }
                }
                .disabled(summary.undone)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func apply(_ renames: [Renamer.Rename]) {
        Task {
            do {
                done = try await model.applyRenames(renames)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
