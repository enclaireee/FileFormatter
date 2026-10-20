import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Convert") {
                    row(
                        "Convert Files",
                        systemImage: "arrow.triangle.2.circlepath",
                        tag: .queue,
                        count: model.items.isEmpty ? nil : model.items.count,
                        showsProgress: model.isRunning
                    )
                }

                Section("Tools") {
                    row(
                        "Watch Folders",
                        systemImage: "folder.badge.gearshape",
                        tag: .watchFolders,
                        count: model.watchRules.filter(\.isEnabled).count
                    )
                    row("Duplicates", systemImage: "square.on.square", tag: .duplicates)
                }

                Section("Activity") {
                    row("History", systemImage: "clock.arrow.circlepath", tag: .history)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("On-device only")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 8)
            .help("No uploads. Every conversion runs on this Mac.")
        }
    }

    private func row(
        _ title: String,
        systemImage: String,
        tag: SidebarSelection,
        count: Int? = nil,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: Theme.Space.xs)
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .help("Converting files")
            } else if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(tag)
    }
}
