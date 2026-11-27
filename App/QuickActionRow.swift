import SwiftUI

/// The likely actions for a set of files: one primary Return-key CTA, plus a clean 2-column grid with "More…".
/// Shared by the menu bar popover and (compact) the queue header.
struct QuickActionRow: View {
    let urls: [URL]
    var compact = false
    let perform: (QuickAction) -> Void

    var body: some View {
        let suggested = QuickAction.suggestions(for: urls)
        let primary = suggested.first
        let secondaryLimit = (suggested.count > 4 || !QuickAction.otherFormats(for: urls).isEmpty) ? 3 : 4
        let secondary = Array(suggested.dropFirst().prefix(secondaryLimit))
        let shownSet = Set(([primary].compactMap { $0 }) + secondary)
        let more = suggested.filter { !shownSet.contains($0) }
            + QuickAction.otherFormats(for: urls).filter { !shownSet.contains($0) }

        Group {
            if compact {
                FlowLayout(spacing: 6) {
                    if let primary {
                        button(primary).buttonStyle(.borderedProminent)
                    }
                    ForEach(secondary) { action in
                        button(action)
                    }
                    otherMenu(more, fillTile: false)
                }
                .controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    if let primary {
                        Button { run(primary) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: primary.systemImage)
                                    .font(.body.weight(.semibold))
                                Text(primary.actionTitle)
                                    .font(.body.weight(.semibold))
                                Spacer(minLength: 4)
                                Text("↩")
                                    .font(.caption.weight(.semibold))
                                    .opacity(0.75)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .help("\(primary.actionTitle) (Return)")
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                        ForEach(Array(secondary.enumerated()), id: \.element) { idx, action in
                            tileButton(action, shortcutIndex: idx + 1)
                        }
                        if !more.isEmpty {
                            otherMenu(more, fillTile: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    private func tileButton(_ action: QuickAction, shortcutIndex: Int) -> some View {
        let key = KeyEquivalent(Character("\(shortcutIndex)"))
        return Button { run(action) } label: {
            HStack(spacing: 7) {
                Image(systemName: action.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(action.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline.opacity(0.45), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(action.actionTitle) (⌘\(shortcutIndex))")
    }

    private func button(_ action: QuickAction) -> some View {
        Button { run(action) } label: {
            Label(action.title, systemImage: action.systemImage).lineLimit(1)
        }
        .help(action.actionTitle)
    }

    @ViewBuilder
    private func otherMenu(_ actions: [QuickAction], fillTile: Bool) -> some View {
        if !actions.isEmpty {
            if fillTile {
                Menu {
                    ForEach(actions) { action in
                        Button {
                            run(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("More…")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.Palette.hairline.opacity(0.45), lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
            } else {
                Menu("More formats") {
                    ForEach(actions) { action in
                        Button(action.title) { run(action) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
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
