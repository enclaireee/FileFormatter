import SwiftUI

struct SettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    var body: some View {
        Form {
            Section("FileFormatter") {
                LabeledContent("Version", value: version)
                Text("A local-only batch converter. Files are read and written on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("No network access", systemImage: "lock.shield")
                Label("OCR and conversion run on-device", systemImage: "cpu")
                Label("Originals are never deleted by the app", systemImage: "checkmark.shield")
            }

            Section("Supported in this build") {
                Text("Images: JPEG, PNG, HEIC, AVIF, WebP, TIFF")
                Text("Data: CSV, TSV, JSON, YAML, TOML")
                Text("Documents: images → one-page PDF")
                Text("More families arrive in the next milestones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
