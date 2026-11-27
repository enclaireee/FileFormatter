import AppKit
import SwiftUI

/// Menu bar icon + popover. Files dropped on the icon or on the drag-anywhere shelf are staged and the popover opens.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination, NSPopoverDelegate {
    static let shared = StatusItemController()

    private let state = QuickConvertState()
    private let popover = NSPopover()
    private let shelf = DropShelf()
    private var item: NSStatusItem?
    private var clickMonitors: [Any] = []
    private var downLocation: NSPoint?
    private var downDragCount = 0
    private var wasBusy = false
    private var showCheckmarkUntil: Date?

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let button = item.button {
            button.image = idleIcon()
            button.target = self
            button.action = #selector(toggle)
            // The status bar window forwards dragging messages to its delegate; sturdier than an overlay view.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        // Not .transient: that closes the popover the moment a drag starts in Finder. Outside clicks close it instead.
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: QuickConvertView(state: state, model: .shared, reopen: { [weak self] in self?.show() })
        )
        shelf.shouldShow = { [weak self] in
            AppSettings.bool(AppSettings.shelfEnabled) && NSApp.modalWindow == nil && !(self?.popover.isShown ?? true)
        }
        shelf.onDrop = { [weak self] urls in
            guard let self else { return }
            state.stage(urls)
            show(from: shelf.anchor)
        }
        shelf.start()
        HotKey.shared.onPress = { [weak self] in self?.hotkeyPressed() }
        HotKey.shared.apply()
        observeProgress()
    }

    private func observeProgress() {
        withObservationTracking {
            let model = AppModel.shared
            let busy = model.isRunning || model.isQuickRunning
            let fraction: Double
            if model.isRunning {
                fraction = model.progress
            } else if model.isQuickRunning {
                let total = max(model.quickItems.count, 1)
                let done = model.quickItems.filter(\.status.isTerminal).count
                let partial = model.quickItems.first(where: { $0.status == .converting })?.progress ?? 0
                fraction = min(1.0, (Double(done) + partial) / Double(total))
            } else {
                fraction = 0
            }
            updateStatusIcon(busy: busy, progress: fraction)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeProgress()
            }
        }
    }

    private func updateStatusIcon(busy: Bool, progress: Double) {
        guard let button = item?.button else { return }
        if busy {
            wasBusy = true
            showCheckmarkUntil = nil
            button.image = progressRingIcon(progress: progress)
            return
        }
        if wasBusy {
            wasBusy = false
            let deadline = Date().addingTimeInterval(2.0)
            showCheckmarkUntil = deadline
            let checkmark = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Conversion finished")
            checkmark?.isTemplate = true
            button.image = checkmark
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let until = self.showCheckmarkUntil, Date() >= until, !AppModel.shared.isBusy else { return }
                self.showCheckmarkUntil = nil
                self.item?.button?.image = self.idleIcon()
            }
            return
        }
        if showCheckmarkUntil == nil {
            button.image = idleIcon()
        }
    }

    private func idleIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FileFormatter")
        image?.isTemplate = true
        return image
    }

    private func progressRingIcon(progress: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.8
            NSColor.black.withAlphaComponent(0.28).setStroke()
            let track = NSBezierPath()
            track.lineWidth = 2.1
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.stroke()

            let clamped = max(0.08, min(1.0, progress))
            let startAngle: CGFloat = 90
            let endAngle: CGFloat = 90 - CGFloat(clamped) * 360
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 2.1
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            arc.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    private func hotkeyPressed() {
        if popover.isShown { return popover.performClose(nil) }
        guard NSApp.modalWindow == nil else { return }
        // ponytail: always the top-right anchor, since the notch can hide the icon and macOS doesn't say when.
        shelf.showAnchor()
        show(from: shelf.anchor)
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    private func show(from view: NSView? = nil) {
        guard let anchor = view ?? item?.button else { return }
        if popover.isShown {
            guard view != nil else { return }
            popover.close()
        }
        // The shelf hugs the screen's right edge; pointing from its left edge keeps the popover on screen.
        let rect = view == nil ? anchor.bounds : NSRect(x: 0, y: 0, width: 1, height: anchor.bounds.height)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Popover

    func popoverDidShow(_ notification: Notification) {
        // A click elsewhere closes the popover; a drag that starts elsewhere (to drop files here) does not.
        // Avoids monitoring .leftMouseDragged so cursor movement never wakes the process at 120 Hz.
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .leftMouseDown, .rightMouseDown:
                    self.downLocation = NSEvent.mouseLocation
                    self.downDragCount = NSPasteboard(name: .drag).changeCount
                default:
                    let now = NSEvent.mouseLocation
                    let moved = self.downLocation.map { hypot(now.x - $0.x, now.y - $0.y) > 8 } ?? false
                    let startedFileDrag = NSPasteboard(name: .drag).changeCount != self.downDragCount
                    if !moved && !startedFileDrag {
                        self.popover.performClose(nil)
                    }
                }
            }
        }) { clickMonitors.append(monitor) }
    }

    func popoverDidClose(_ notification: Notification) {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        shelf.dismiss()
    }

    // MARK: Drops on the menu bar icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        item?.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        item?.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item?.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        shelf.dismiss()
        state.stage(urls)
        show()
        return true
    }
}
