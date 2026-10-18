import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Presets") {
                ForEach(Preset.builtIn) { preset in
                    Button {
                        model.apply(preset)
                        selection = .queue
                    } label: {
                        HStack(spacing: 8) {
                            Label(preset.name, systemImage: preset.systemImage)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if model.activePreset?.id == preset.id {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Convert") {
                Label("Queue", systemImage: "square.stack.3d.up")
                    .tag(SidebarSelection.queue)
            }
            Section("Tools") {
                Label("Watch Folders", systemImage: "folder.badge.gearshape")
                    .tag(SidebarSelection.watchFolders)
                Label("Duplicates", systemImage: "square.on.square")
                    .tag(SidebarSelection.duplicates)
            }
            Section("Activity") {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.history)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("Local only")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
        }
    }
}
