import AppKit
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

            Section("Finder actions") {
                Text("Right-click files in Finder, then choose Quick Actions or Services: Convert to JPEG, Convert to PNG, Remove Background, Compress Image, Make PDF, Convert Video to MP4, Make GIF, Extract Audio, or Open in FileFormatter…. You may need to enable them first in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Keyboard Shortcuts…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Supported in this build") {
                Text("Images: JPEG, PNG, HEIC, AVIF, WebP, TIFF")
                Text("Data: CSV, TSV, JSON, YAML, TOML ↔ XLSX")
                Text("Documents: images ↔ PDF; PDF → page images; DOCX/PPTX → Markdown, text, or HTML")
                Text("Media: MP3, M4A, FLAC, WAV, AIFF, Opus, OGG; MP4, MOV, MKV, WebM")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
