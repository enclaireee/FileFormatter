import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Convert") {
                Label("Queue", systemImage: "square.stack.3d.up")
                    .tag(SidebarSelection.queue)
            }
            Section("Activity") {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.history)
            }
            Section("Automation") {
                Label("Watch Folders", systemImage: "folder.badge.gearshape")
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                    .help("Coming with the watch-folder milestone")
                Label("Duplicates", systemImage: "square.on.square")
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                    .help("Coming with the duplicate-finder milestone")
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
