import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if model.isEmpty || model.hasKind(.image) {
                Section("Images") {
                    Picker("Convert to", selection: imageBinding) {
                        ForEach(ConversionTarget.imageTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    if model.imageTarget == .pdf {
                        Text("Each image becomes a one-page PDF. Pages keep the source pixel dimensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.imageTarget.supportsQuality {
                        LabeledContent("Quality") {
                            Text("\(Int(model.quality * 100))%")
                                .monospacedDigit()
                        }
                        Slider(value: $model.quality, in: 0.3...1.0)
                    } else {
                        Text("Lossless output · quality does not apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Preserve metadata", isOn: $model.preserveMetadata)
                }
            }

            if model.hasKind(.data) {
                Section("Data") {
                    Picker("Convert to", selection: dataBinding) {
                        ForEach(ConversionTarget.dataTargets) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    Text("CSV and TSV are read as a table with a header row. JSON output is an array of objects; JSON to CSV requires the same shape.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !unsupportedKinds.isEmpty {
                Section("Other files") {
                    Text("Not convertible yet: \(unsupportedKinds.joined(separator: ", ")). They stay in the queue as skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                TextField("Suffix", text: $model.suffix)
                    .onSubmit { model.scheduleReplan() }
                LabeledContent("Destination", value: "Same folder")
            }

            Section("Plan") {
                if model.isPlanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Planning…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.isEmpty {
                    Text("Add files to see their conversion plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Files", value: "\(model.items.count)")
                    LabeledContent("Ready", value: "\(model.runnableCount)")
                    ForEach(FidelityLevel.allCases, id: \.self) { level in
                        let count = model.items.filter { $0.fidelity == level }.count
                        if count > 0 {
                            LabeledContent(level.label, value: "\(count)")
                        }
                    }
                }
            }

            Section {
                Text("Fidelity is predicted from the source and target. Lossless conversions preserve data; re-encoded files may lose detail or formatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.suffix) { _, _ in
            model.scheduleReplan()
        }
    }

    private var imageBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.imageTarget },
            set: { newValue in
                model.imageTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var dataBinding: Binding<ConversionTarget> {
        Binding(
            get: { model.dataTarget },
            set: { newValue in
                model.dataTarget = newValue
                model.scheduleReplan()
            }
        )
    }

    private var unsupportedKinds: [String] {
        var seen = Set<String>()
        return model.items.compactMap { item in
            guard item.kind != .image, item.kind != .data else { return nil }
            return seen.insert(item.kind.label).inserted ? item.kind.label : nil
        }
    }
}
