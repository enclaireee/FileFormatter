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
    private var dragged = false

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FileFormatter")
            image?.isTemplate = true
            button.image = image
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
        shelf.shouldShow = { [weak self] in !(self?.popover.isShown ?? true) }
        shelf.onDrop = { [weak self] urls in
            guard let self else { return }
            state.stage(urls)
            show(from: shelf.anchor)
        }
        shelf.start()
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
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .leftMouseDown, .rightMouseDown: self.dragged = false
                case .leftMouseDragged: self.dragged = true
                default: if !self.dragged { self.popover.performClose(nil) }
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
