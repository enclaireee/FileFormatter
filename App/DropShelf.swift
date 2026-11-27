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
    private var releaseMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var dragCount = NSPasteboard(name: .drag).changeCount
    private var dropped = false

    /// After a drop the panel stays in place, invisible, so the popover can point at it.
    var anchor: NSView { panel.contentView! }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 96),
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
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncMonitor() }
            }
        }
        syncMonitor()
    }

    private func syncMonitor() {
        let enabled = AppSettings.bool(AppSettings.shelfEnabled)
        if enabled {
            guard monitor == nil else { return }
            dragCount = NSPasteboard(name: .drag).changeCount
            // A new drag rewrites the drag pasteboard; window moves and text selection don't.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                MainActor.assumeIsolated { self?.dragged() }
            }
        } else {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            dismiss()
        }
    }

    private func stopReleaseMonitor() {
        if let releaseMonitor {
            NSEvent.removeMonitor(releaseMonitor)
            self.releaseMonitor = nil
        }
    }

    func dismiss() {
        stopReleaseMonitor()
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

    /// Places the pad invisibly at the top right so the popover can point at it (hotkey, icon hidden by the notch).
    func showAnchor() {
        stopReleaseMonitor()
        place()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }

    private func show() {
        place()
        host.rootView = ShelfPad(targeted: false)
        dropped = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }

        stopReleaseMonitor()
        releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleRelease() }
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            handleRelease()
        }
    }

    private func handleRelease() {
        stopReleaseMonitor()
        // Give the drop a moment to land before hiding the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(targeted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                    .frame(width: 42, height: 42)
                Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(targeted ? Color.accentColor : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "Release to stage" : "Drop to Convert")
                    .font(.callout.weight(.semibold))
                Text("1 click · originals safe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.32),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [6, 4]))
        )
        .scaleEffect(targeted ? 1.02 : 1.0)
        .animation(.snappy(duration: 0.16), value: targeted)
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
