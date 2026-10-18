import AppKit
import SwiftUI

/// Menu bar icon + popover. Files dropped on the icon are staged and the popover opens.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private let state = QuickConvertState()
    private let popover = NSPopover()
    private var item: NSStatusItem?

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
            let drop = DropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onHighlight = { [weak button] in button?.isHighlighted = $0 }
            drop.onClick = { [weak self] in self?.toggle() }
            drop.onDrop = { [weak self] urls in
                self?.state.stage(urls)
                self?.show()
            }
            button.addSubview(drop)
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: QuickConvertView(state: state, model: .shared, reopen: { [weak self] in self?.show() })
        )
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    private func show() {
        guard !popover.isShown, let button = item?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Transparent view over the status button that accepts file drops and forwards clicks.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }
}
