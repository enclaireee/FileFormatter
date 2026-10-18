import SwiftUI

/// The likely actions for a set of files: one primary button, three tiles, the rest in "Other formats".
/// Shared by the menu bar popover and (compact) the queue header.
struct QuickActionRow: View {
    let urls: [URL]
    var compact = false
    let perform: (QuickAction) -> Void

    var body: some View {
        let suggested = QuickAction.suggestions(for: urls)
        let shown = Array(suggested.prefix(4))
        let more = suggested.dropFirst(4) + QuickAction.otherFormats(for: urls).filter { !shown.contains($0) }
        Group {
            if compact {
                FlowLayout(spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, action in
                        if index == 0 {
                            button(action).buttonStyle(.borderedProminent)
                        } else {
                            button(action)
                        }
                    }
                    otherMenu(Array(more))
                }
                .controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    if let primary = shown.first {
                        Button { run(primary) } label: {
                            Label(primary.title, systemImage: primary.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                    HStack(spacing: 8) {
                        ForEach(shown.dropFirst()) { action in
                            Button { run(action) } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: action.systemImage).font(.title3)
                                    Text(action.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .help(action.title)
                        }
                    }
                    otherMenu(Array(more))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    private func button(_ action: QuickAction) -> some View {
        Button { run(action) } label: {
            Label(action.title, systemImage: action.systemImage).lineLimit(1)
        }
        .help(action.title)
    }

    @ViewBuilder
    private func otherMenu(_ actions: [QuickAction]) -> some View {
        if !actions.isEmpty {
            Menu("Other formats") {
                ForEach(actions) { action in
                    Button(action.title) { run(action) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private func run(_ action: QuickAction) {
        QuickAction.remember(action, for: urls)
        perform(action)
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(width: bounds.width, subviews: subviews)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: layout.widths[index], height: nil)
            )
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], widths: [CGFloat], size: CGSize) {
        var origins: [CGPoint] = [], widths: [CGFloat] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widths.append(size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, widths, CGSize(width: maxX, height: y + rowHeight))
    }
}
