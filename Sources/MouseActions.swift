import AppKit
import Carbon.HIToolbox

/// What a mouse button can do, like the actions in BetterTouchTool, LinearMouse or MiddleClick.
/// The first three keep the names saved by earlier versions.
enum MouseAction: String, CaseIterable, Identifiable, Codable {
    case none, moveLeftSpace, moveRightSpace
    case missionControl, appWindows, showDesktop, showApps
    case back, forward, newTab, closeTab, reopenTab, nextTab, previousTab, refresh
    case copy, paste, cut, undo, redo, selectAll
    case middleClick, commandClick
    case zoomIn, zoomOut
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case spotlight, switchApp, hideApp, minimize, fullScreen, lockScreen
    case captureArea, captureFullscreen, captureText
    case customShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nothing (normal button)"
        case .moveLeftSpace: return "Move Left a Space"
        case .moveRightSpace: return "Move Right a Space"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App Windows (App Exposé)"
        case .showDesktop: return "Show Desktop"
        case .showApps: return "Show Apps (Launchpad)"
        case .back: return "Back"
        case .forward: return "Forward"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab or Window"
        case .reopenTab: return "Reopen Closed Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .refresh: return "Reload Page"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAll: return "Select All"
        case .middleClick: return "Middle Click"
        case .commandClick: return "Open Link in New Tab (⌘-Click)"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .spotlight: return "Spotlight Search"
        case .switchApp: return "Switch App (⌘Tab)"
        case .hideApp: return "Hide App"
        case .minimize: return "Minimize Window"
        case .fullScreen: return "Full Screen"
        case .lockScreen: return "Lock Screen"
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureText: return "Capture Text (OCR)"
        case .customShortcut: return "Keyboard Shortcut of Your Own…"
        }
    }

    var group: String {
        switch self {
        case .none: return "Default"
        case .moveLeftSpace, .moveRightSpace, .missionControl, .appWindows, .showDesktop, .showApps: return "Desktops and windows"
        case .back, .forward, .newTab, .closeTab, .reopenTab, .nextTab, .previousTab, .refresh: return "Browser and tabs"
        case .copy, .paste, .cut, .undo, .redo, .selectAll: return "Editing"
        case .middleClick, .commandClick: return "Clicks"
        case .zoomIn, .zoomOut: return "Zoom"
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute: return "Media"
        case .spotlight, .switchApp, .hideApp, .minimize, .fullScreen, .lockScreen: return "System"
        case .captureArea, .captureFullscreen, .captureText: return "MicFlow Capture"
        case .customShortcut: return "Keyboard"
        }
    }

    static let groups = ["Default", "Desktops and windows", "Browser and tabs", "Editing", "Clicks", "Zoom", "Media",
                         "System", "MicFlow Capture", "Keyboard"]

    /// Set by the app: starts one of MicFlow's capture tools.
    @MainActor static var capture: ((CaptureAction) -> Void)?

    /// Does the action. `location` is where the mouse is, for clicks.
    @MainActor
    func perform(at location: CGPoint? = nil) {
        switch self {
        case .none: return
        case .moveLeftSpace: SwipeGestureController.perform(.moveLeftSpace)
        case .moveRightSpace: SwipeGestureController.perform(.moveRightSpace)
        case .missionControl: Self.missionControl([])
        case .appWindows: Self.missionControl(["2"])
        case .showDesktop: Self.missionControl(["1"])
        case .showApps:
            let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            if let path = apps.first(where: FileManager.default.fileExists) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        case .back: Self.key(kVK_ANSI_LeftBracket, .maskCommand)
        case .forward: Self.key(kVK_ANSI_RightBracket, .maskCommand)
        case .newTab: Self.key(kVK_ANSI_T, .maskCommand)
        case .closeTab: Self.key(kVK_ANSI_W, .maskCommand)
        case .reopenTab: Self.key(kVK_ANSI_T, [.maskCommand, .maskShift])
        case .nextTab: Self.key(kVK_Tab, .maskControl)
        case .previousTab: Self.key(kVK_Tab, [.maskControl, .maskShift])
        case .refresh: Self.key(kVK_ANSI_R, .maskCommand)
        case .copy: Self.key(kVK_ANSI_C, .maskCommand)
        case .paste: Self.key(kVK_ANSI_V, .maskCommand)
        case .cut: Self.key(kVK_ANSI_X, .maskCommand)
        case .undo: Self.key(kVK_ANSI_Z, .maskCommand)
        case .redo: Self.key(kVK_ANSI_Z, [.maskCommand, .maskShift])
        case .selectAll: Self.key(kVK_ANSI_A, .maskCommand)
        case .middleClick: Self.click(.center, at: location, flags: [])
        case .commandClick: Self.click(.left, at: location, flags: .maskCommand)
        case .zoomIn: Self.key(kVK_ANSI_Equal, .maskCommand)
        case .zoomOut: Self.key(kVK_ANSI_Minus, .maskCommand)
        case .playPause: Self.media(NX_KEYTYPE_PLAY)
        case .nextTrack: Self.media(NX_KEYTYPE_FAST)
        case .previousTrack: Self.media(NX_KEYTYPE_REWIND)
        case .volumeUp: Self.media(NX_KEYTYPE_SOUND_UP)
        case .volumeDown: Self.media(NX_KEYTYPE_SOUND_DOWN)
        case .mute: Self.media(NX_KEYTYPE_MUTE)
        case .spotlight: Self.key(kVK_Space, .maskCommand)
        case .switchApp: Self.key(kVK_Tab, .maskCommand)
        case .hideApp: Self.key(kVK_ANSI_H, .maskCommand)
        case .minimize: Self.key(kVK_ANSI_M, .maskCommand)
        case .fullScreen: Self.key(kVK_ANSI_F, [.maskCommand, .maskControl])
        case .lockScreen: Self.key(kVK_ANSI_Q, [.maskCommand, .maskControl])
        case .captureArea: Self.capture?(.area)
        case .captureFullscreen: Self.capture?(.fullscreen)
        case .captureText: Self.capture?(.text)
        // Done by the mapping, which holds the keys.
        case .customShortcut: return
        }
    }

    /// Marks the clicks MicFlow sends itself, so the mouse-button tap lets them through.
    static let marker: Int64 = 0x4D42_4D42

    static func key(_ code: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// A custom shortcut, with Carbon modifiers as `Shortcut` stores them.
    static func key(_ shortcut: Shortcut) {
        var flags: CGEventFlags = []
        if shortcut.modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if shortcut.modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if shortcut.modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if shortcut.modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        key(shortcut.keyCode, flags)
    }

    private static func click(_ button: CGMouseButton, at location: CGPoint?, flags: CGEventFlags) {
        let point = location ?? CGEvent(source: nil)?.location ?? .zero
        let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.otherMouseDown, .otherMouseUp)
        for type in [down, up] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Media and volume keys, as the keyboard's own keys send them.
    private static func media(_ key: Int32) {
        for isDown in [true, false] {
            let data1 = Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Mission Control; "1" shows the desktop and "2" the front app's windows.
    private static func missionControl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        process.arguments = arguments
        try? process.run()
    }
}

/// A mouse button you added yourself, and what it does.
struct ButtonMapping: Codable, Identifiable, Equatable {
    var button: Int64
    var action: MouseAction
    /// Used when `action` is nil-like: a keyboard shortcut of your own.
    var shortcut: Shortcut?
    var id: Int64 { button }

    static func name(of button: Int64) -> String {
        switch button {
        case 2: return "Middle button"
        case 3: return "Side button 1 (Back)"
        case 4: return "Side button 2 (Forward)"
        default: return "Button \(button + 1)"
        }
    }
}
