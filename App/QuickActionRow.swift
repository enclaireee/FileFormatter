import SwiftUI

/// One-click buttons for the likely actions on a set of files. Shared by the menu bar popover and the queue header.
struct QuickActionRow: View {
    let urls: [URL]
    var limit = 8
    var controlSize: ControlSize = .regular
    let perform: (QuickAction) -> Void

    var body: some View {
        let actions = QuickAction.suggestions(for: urls, limit: limit)
        FlowLayout(spacing: 6) {
            ForEach(actions) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .lineLimit(1)
                }
                .controlSize(controlSize)
                .help(action.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
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
