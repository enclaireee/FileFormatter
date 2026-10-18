import FileFormatterCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Format") {
                Picker("Convert to", selection: $model.target) {
                    ForEach(ConversionTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                if model.target.supportsQuality {
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
            }

            Section("Output") {
                TextField("Suffix", text: $model.suffix)
                    .onSubmit { model.scheduleReplan() }
                Toggle("Preserve metadata", isOn: $model.preserveMetadata)
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
                Text("Fidelity is predicted from the source and target. Lossless conversions preserve pixels; re-encoded files may lose detail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.target) { _, _ in
            model.scheduleReplan()
        }
        .onChange(of: model.suffix) { _, _ in
            model.scheduleReplan()
        }
    }
}
