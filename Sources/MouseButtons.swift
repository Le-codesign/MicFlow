import AppKit
import ApplicationServices

/// Space switching from a regular mouse's side buttons, pressed alone or while the right button is
/// held, like the Magic Mouse's swipe gestures. A side button used this way no longer sends
/// Back/Forward.
///
/// For the right-button combinations, the right press is held back until it's clear whether a side
/// button follows: if one does, the right click never happens; if not, it's sent when the button is
/// released (so context menus open on release). Dragging with the right button sends it at once.
final class MouseButtonController {
    enum State: Equatable {
        case off, needsAccessibility, running
    }

    enum Trigger: String, CaseIterable, Identifiable {
        case side1, side2, rightSide1, rightSide2
        var id: String { rawValue }

        var title: String {
            switch self {
            case .side1: return "Side button 1 (Back)"
            case .side2: return "Side button 2 (Forward)"
            case .rightSide1: return "Hold Right + Side button 1"
            case .rightSide2: return "Hold Right + Side button 2"
            }
        }

        /// Mouse button numbers as macOS counts them: 3 is the first side button, 4 the second.
        fileprivate var sideButton: Int64 { self == .side1 || self == .rightSide1 ? 3 : 4 }
        fileprivate var withRight: Bool { self == .rightSide1 || self == .rightSide2 }

        fileprivate static func of(sideButton: Int64, withRight: Bool) -> Trigger? {
            allCases.first { $0.sideButton == sideButton && $0.withRight == withRight }
        }
    }

    var actions: [Trigger: MouseAction] = [:]
    /// Buttons you added yourself; these come before the side-button actions above.
    var mappings: [ButtonMapping] = []
    /// While set, the next extra mouse button pressed is reported here (and does nothing else).
    var onButtonRecorded: ((Int64) -> Void)?
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    /// Tags the right-button events we send ourselves, so the tap lets them through.
    private static let marker: Int64 = MouseAction.marker

    private enum RightButton {
        case up
        /// Pressed and held back: the press, waiting to see whether a side button follows.
        case holding(CGEvent)
        /// Pressed and already sent on (the user started dragging).
        case passedOn
        /// Pressed and used for a combination: no right click at all.
        case usedForCombo
    }

    private var right = RightButton.up
    /// Side buttons whose release must be swallowed too, because their press was.
    private var swallowedSides: Set<Int64> = []
    private lazy var tap = EventTap(types: [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseUp]) {
        [unowned self] type, event in self.handle(type, event)
    }
    private var timer: Timer?

    private var holdsRightButton: Bool {
        Trigger.allCases.contains { $0.withRight && (actions[$0] ?? MouseAction.none) != MouseAction.none }
    }

    func start() {
        guard timer == nil else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Re-checks until Accessibility permission is granted.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        tap.remove()
        right = .up
        swallowedSides = []
        setState(.off)
    }

    private func update() {
        guard AXIsProcessTrusted(), tap.install() else {
            tap.remove()
            setState(.needsAccessibility)
            return
        }
        setState(.running)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Returns false to drop the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        switch type {
        case .rightMouseDown:
            guard holdsRightButton, let press = event.copy() else { return true }
            right = .holding(press)
            return false
        case .rightMouseDragged:
            switch right {
            case .holding(let press):
                // A right-drag, not a combination: send the press now and let the drag through.
                send(press)
                right = .passedOn
                return true
            case .usedForCombo:
                return false
            case .up, .passedOn:
                return true
            }
        case .rightMouseUp:
            defer { right = .up }
            switch right {
            case .holding(let press):
                // A plain right click: send the press, then the release, in order.
                send(press)
                if let release = event.copy() { send(release) }
                return false
            case .usedForCombo:
                return false
            case .up, .passedOn:
                return true
            }
        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if let report = onButtonRecorded, button >= 2 {
                onButtonRecorded = nil
                swallowedSides.insert(button)
                MainActor.assumeIsolated { report(button) }
                return false
            }
            if case .up = right, let mapping = mappings.first(where: { $0.button == button }), mapping.action != .none {
                swallowedSides.insert(button)
                let location = event.location
                MainActor.assumeIsolated {
                    if mapping.action == .customShortcut {
                        if let shortcut = mapping.shortcut { MouseAction.key(shortcut) }
                    } else {
                        mapping.action.perform(at: location)
                    }
                }
                return false
            }
            guard button == 3 || button == 4 else { return true }
            var withRight = false
            if case .holding = right { withRight = true }
            if case .usedForCombo = right { withRight = true }
            guard let trigger = Trigger.of(sideButton: button, withRight: withRight),
                  let action = actions[trigger], action != .none else { return true }
            if withRight { right = .usedForCombo }
            swallowedSides.insert(button)
            let location = event.location
            MainActor.assumeIsolated { action.perform(at: location) }
            return false
        case .otherMouseUp:
            return swallowedSides.remove(event.getIntegerValueField(.mouseEventButtonNumber)) == nil
        default:
            return true
        }
    }

    private func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
