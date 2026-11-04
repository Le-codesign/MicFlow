import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One-finger swipes on the Magic Mouse that switch Spaces, like BetterTouchTool's "Move Left/Right
/// a Space". MicFlow presses the keyboard shortcut set for that in System Settings › Keyboard ›
/// Keyboard Shortcuts › Mission Control, reading it each time so a customized shortcut still works.
final class SwipeGestureController {
    enum State: Equatable {
        case off, needsAccessibility, noMagicMouse, shortcutOff, running
    }

    enum Action: String, CaseIterable, Identifiable {
        case none, moveLeftSpace, moveRightSpace
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "Nothing"
            case .moveLeftSpace: return "Move Left a Space"
            case .moveRightSpace: return "Move Right a Space"
            }
        }

        /// The Mission Control shortcut's ID in com.apple.symbolichotkeys, and macOS's default.
        fileprivate var shortcut: (id: String, defaultKey: CGKeyCode)? {
            switch self {
            case .none: return nil
            case .moveLeftSpace: return ("79", CGKeyCode(kVK_LeftArrow))
            case .moveRightSpace: return ("81", CGKeyCode(kVK_RightArrow))
            }
        }
    }

    var leftAction = Action.moveRightSpace
    var rightAction = Action.moveLeftSpace
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private let touches = MagicMouseTouchMonitor.shared
    private var timer: Timer?
    private var swipeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        touches.addUser()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        swipeObserver = NotificationCenter.default.addObserver(forName: .magicMouseSwipe, object: nil, queue: .main) { [weak self] note in
            guard let self, self.state == .running, let direction = note.object as? SwipeDirection else { return }
            Self.perform(direction == .left ? self.leftAction : self.rightAction)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.touches.refresh(force: true)
        }
        // Re-checks for permission, the mouse reconnecting, and the shortcuts being switched on.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        for observer in [swipeObserver, wakeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        (swipeObserver, wakeObserver) = (nil, nil)
        touches.removeUser()
        setState(.off)
    }

    /// Re-checks state now, e.g. after an action was changed.
    func update() {
        guard timer != nil else { return }
        touches.refresh()
        if !AXIsProcessTrusted() {
            setState(.needsAccessibility)
        } else if !touches.isTracking {
            setState(.noMagicMouse)
        } else if [leftAction, rightAction].contains(where: { $0 != .none && Self.keystroke(for: $0) == nil }) {
            setState(.shortcutOff)
        } else {
            setState(.running)
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Presses the action's Mission Control shortcut; also used by the mouse-button actions.
    static func perform(_ action: Action) {
        guard let (key, flags) = Self.keystroke(for: action) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// The key and modifiers for an action's Mission Control shortcut, or nil when it's switched off.
    static func keystroke(for action: Action) -> (CGKeyCode, CGEventFlags)? {
        guard let shortcut = action.shortcut else { return nil }
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = hotkeys?[shortcut.id] as? [String: Any] else {
            // Never customized: macOS's default, Control-arrow, which is on.
            return (shortcut.defaultKey, arrowFlags.union(.maskControl))
        }
        guard (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 else { return nil }
        let key = CGKeyCode(parameters[1])
        var flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        if (123...126).contains(Int(key)) { flags.formUnion(arrowFlags) }
        return (key, flags)
    }

    /// Arrow keys carry these flags when typed on a real keyboard; Mission Control expects them.
    private static let arrowFlags: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]
}
