import AppKit
import ApplicationServices

// MARK: Middle click

/// Turns a Magic Mouse click made with a finger in the middle of the mouse into a middle click.
/// The rest of the press (dragging, release) follows as middle-button events too, so holding it
/// down to scroll or pan works in apps that support that.
final class MiddleClickController {
    enum State: Equatable {
        case off, needsAccessibility, noMagicMouse, running
    }

    /// Width of the middle area, as a fraction of the mouse's width.
    var zoneWidth: Float = 0.3
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private let touches = MagicMouseTouchMonitor.shared
    private lazy var tap = EventTap(types: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                            .rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [unowned self] type, event in
        self.handle(type, event)
        return true
    }
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// The original button-down type while a converted press is held.
    private var heldDown: CGEventType?

    func start() {
        guard timer == nil else { return }
        touches.addUser()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Re-checks for permission being granted and for the mouse connecting or reconnecting.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.touches.refresh(force: true)
        }
        update()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        removeTap()
        touches.removeUser()
        setState(.off)
    }

    private func update() {
        guard AXIsProcessTrusted() else {
            removeTap()
            setState(.needsAccessibility)
            return
        }
        touches.refresh()
        guard touches.isTracking else {
            removeTap()
            setState(.noMagicMouse)
            return
        }
        setState(tap.install() ? .running : .needsAccessibility)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    private func removeTap() {
        tap.remove()
        heldDown = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            if heldDown == nil, fingerIsInMiddle() {
                heldDown = type
                makeMiddle(event, .otherMouseDown)
            }
        case .leftMouseDragged, .rightMouseDragged:
            if let heldDown, (heldDown == .leftMouseDown) == (type == .leftMouseDragged) {
                makeMiddle(event, .otherMouseDragged)
            }
        case .leftMouseUp, .rightMouseUp:
            if let held = heldDown, (held == .leftMouseDown) == (type == .leftMouseUp) {
                makeMiddle(event, .otherMouseUp)
                heldDown = nil
            }
        default:
            break
        }
    }

    /// True when every finger on the mouse is inside the middle area, so a normal left or right
    /// click with another finger resting in the middle stays a normal click.
    private func fingerIsInMiddle() -> Bool {
        let xs = touches.touches
        return !xs.isEmpty && xs.allSatisfy { abs($0 - 0.5) <= zoneWidth / 2 }
    }

    private func makeMiddle(_ event: CGEvent, _ type: CGEventType) {
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
    }
}
