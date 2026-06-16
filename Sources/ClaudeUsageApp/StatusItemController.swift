import AppKit
import SwiftUI
import Combine
import ClaudeUsageCore

/// Owns the menu bar status item: draws the ring icon, shows the tooltip popover on hover,
/// pins it open on click, and offers Refresh/Quit on right-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    private var hoverView: HoverView?
    /// Pinned (clicked) popovers ignore hover-close until clicked again or dismissed.
    private var pinned = false
    private var hoverMonitor: Timer?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: TooltipView(state: state))

        configureButton()
        observeState()
        updateIcon()
    }

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = RingIconRenderer.render(fiveHour: nil, sevenDay: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Transparent overlay that reports hover enter/exit without intercepting clicks.
        let hover = HoverView(frame: button.bounds)
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { [weak self] in self?.handleMouseEntered() }
        hover.onExit = { [weak self] in self?.handleMouseExited() }
        button.addSubview(hover)
        hoverView = hover
    }

    private func observeState() {
        // Redraw the icon whenever usage changes.
        state.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        statusItem.button?.image = RingIconRenderer.render(
            fiveHour: state.usage?.fiveHour?.utilization,
            sevenDay: state.usage?.sevenDay?.utilization
        )
    }

    // MARK: Clicks

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showMenu()
        } else {
            togglePinned()
        }
    }

    private func togglePinned() {
        if popover.isShown && pinned {
            closePopover()
        } else {
            pinned = true
            stopHoverMonitor()
            showPopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claude Usage", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        }
    }

    @objc private func refreshAction() { state.manualRefresh() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    // MARK: Hover

    private func handleMouseEntered() {
        if !popover.isShown { showPopover() }
        if !pinned { startHoverMonitor() }
    }

    private func handleMouseExited() {
        // The repeating monitor handles the actual close once the cursor is outside both
        // the button and the popover (so moving into the popover keeps it open).
        if !pinned { startHoverMonitor() }
    }

    private func startHoverMonitor() {
        guard hoverMonitor == nil else { return }
        // Add to .common modes so the close check keeps firing during event tracking
        // (e.g. while a right-click menu is open or a drag is in progress); a
        // .default-mode scheduledTimer would pause and leave the popover stuck open.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hoverTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverMonitor = timer
    }

    private func stopHoverMonitor() {
        hoverMonitor?.invalidate()
        hoverMonitor = nil
    }

    private func hoverTick() {
        guard popover.isShown, !pinned else { stopHoverMonitor(); return }
        if !isMouseInsidePopoverOrButton() {
            closePopover()
        }
    }

    private func isMouseInsidePopoverOrButton() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let button = statusItem.button, let window = button.window {
            let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
            // Pad downward to bridge the small gap to the popover below.
            if inScreen.insetBy(dx: -3, dy: -8).contains(mouse) { return true }
        }
        if popover.isShown, let popWindow = popover.contentViewController?.view.window {
            if popWindow.frame.insetBy(dx: -3, dy: -8).contains(mouse) { return true }
        }
        return false
    }

    // MARK: Popover

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        stopHoverMonitor()
        if popover.isShown { popover.performClose(nil) }
    }

    // NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        pinned = false
        stopHoverMonitor()
    }
}

/// Transparent tracking overlay placed over the status button. Reports hover enter/exit
/// via closures but passes clicks through to the button beneath it.
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    // Pass clicks through to the status button below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
