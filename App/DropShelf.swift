import AppKit
import SwiftUI

/// A floating "drop here" pad that appears near the top-right of the screen while files are dragged anywhere.
/// Watches global mouse drags (no Accessibility permission needed) and the drag pasteboard.
@MainActor
final class DropShelf {
    var onDrop: ([URL]) -> Void = { _ in }
    var shouldShow: () -> Bool = { true }

    private let panel: NSPanel
    private let host = NSHostingView(rootView: ShelfPad(targeted: false))
    private var monitor: Any?
    private var dragCount = NSPasteboard(name: .drag).changeCount
    private var poll: Timer?
    private var dropped = false

    /// After a drop the panel stays in place, invisible, so the popover can point at it.
    var anchor: NSView { panel.contentView! }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 110),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let drop = DropView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        drop.onHighlight = { [weak self] in self?.host.rootView = ShelfPad(targeted: $0) }
        drop.onDrop = { [weak self] urls in
            self?.dropped = true
            self?.onDrop(urls)
        }
        panel.contentView = drop
    }

    func start() {
        guard monitor == nil else { return }
        // A new drag rewrites the drag pasteboard; window moves and text selection don't.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }
    }

    func dismiss() {
        poll?.invalidate()
        poll = nil
        panel.orderOut(nil)
    }

    private func dragged() {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragCount else { return }
        dragCount = pasteboard.changeCount
        guard !panel.isVisible, shouldShow(),
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return }
        show()
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
        host.rootView = ShelfPad(targeted: false)
        dropped = false
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReleased() }
        }
    }

    private func checkReleased() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        poll?.invalidate()
        poll = nil
        // Give the drop a moment to land before hiding the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if dropped {
                // ponytail: invisible anchor for the popover; dismissed when the popover closes.
                panel.alphaValue = 0
                panel.ignoresMouseEvents = true
            } else {
                panel.orderOut(nil)
            }
        }
    }
}

private struct ShelfPad: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 28))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop to convert")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: targeted ? [] : [6, 4]))
        )
        .accessibilityElement(children: .combine)
    }
}

/// Plain view that accepts file drops; SwiftUI content can sit on top of it.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
}
