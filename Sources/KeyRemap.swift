import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hid

/// A key, or a key's job, as macOS's key remapping names it: HID usage page in the upper 32 bits,
/// usage in the lower.
struct KeyChoice: Hashable, Identifiable {
    let name: String
    let usage: UInt64
    var id: UInt64 { usage }

    private static func key(_ name: String, _ usage: UInt64) -> KeyChoice { KeyChoice(name: name, usage: 0x7_0000_0000 | usage) }
    private static func media(_ name: String, _ usage: UInt64) -> KeyChoice { KeyChoice(name: name, usage: 0xC_0000_0000 | usage) }

    /// MicFlow listens for this otherwise unused key (F20) and switches the input language.
    static let switchLanguage = KeyChoice(name: "Switch input language", usage: 0x7_0000_006F)
    static let fnGlobe = KeyChoice(name: "Fn / Globe", usage: 0xFF_0000_0003)

    /// Keys on a keyboard that can be remapped, named for a Windows keyboard first.
    static let keys: [KeyChoice] = {
        var keys = [
            key("Left Ctrl", 0xE0), key("Left Windows (Cmd)", 0xE3), key("Left Alt (Option)", 0xE2), key("Left Shift", 0xE1),
            key("Right Ctrl", 0xE4), key("Right Windows (Cmd)", 0xE7), key("Right Alt (Option)", 0xE6), key("Right Shift", 0xE5),
            key("Caps Lock", 0x39), key("Menu", 0x65), key("Escape", 0x29), key("Tab", 0x2B), key("Enter", 0x28),
            key("Backspace", 0x2A), key("Delete", 0x4C), key("Space", 0x2C),
            key("Insert", 0x49), key("Home", 0x4A), key("End", 0x4D), key("Page Up", 0x4B), key("Page Down", 0x4E),
            key("Up Arrow", 0x52), key("Down Arrow", 0x51), key("Left Arrow", 0x50), key("Right Arrow", 0x4F),
            key("Print Screen", 0x46), key("Scroll Lock", 0x47), key("Pause", 0x48),
        ]
        keys += (1...12).map { key("F\($0)", 0x3A + UInt64($0 - 1)) }
        keys += (13...19).map { key("F\($0)", 0x68 + UInt64($0 - 13)) }
        keys += "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated().map { key(String($1), 0x04 + UInt64($0)) }
        keys += (1...9).map { key("\($0)", 0x1E + UInt64($0 - 1)) } + [key("0", 0x27)]
        keys += [key("- (minus)", 0x2D), key("= (equals)", 0x2E), key("[", 0x2F), key("]", 0x30), key("\\", 0x31),
                 key(";", 0x33), key("' (quote)", 0x34), key("` (backtick)", 0x35), key(",", 0x36), key(".", 0x37), key("/", 0x38)]
        return keys
    }()

    /// What a key can be turned into: any key above, or one of these jobs.
    static let targets: [KeyChoice] = [
        switchLanguage, fnGlobe,
        media("Volume Up", 0xE9), media("Volume Down", 0xEA), media("Mute", 0xE2),
        media("Play / Pause", 0xCD), media("Next Track", 0xB5), media("Previous Track", 0xB6),
        media("Brightness Up", 0x6F), media("Brightness Down", 0x70),
    ] + keys

    static func named(_ usage: UInt64) -> KeyChoice? { targets.first { $0.usage == usage } }
}

struct KeyRemap: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: UInt64
    var to: UInt64
}

/// Remaps keys on every connected keyboard with macOS's own key remapping (the `UserKeyMapping`
/// property that `hidutil` and System Settings › Keyboard › Modifier Keys use), so swaps like
/// Ctrl ⇄ Cmd work at once. "Switch input language" maps the key to F20, which an event tap
/// catches to select the next input source.
///
/// Karabiner-Elements reads keyboards before macOS's remapping does, so while it's active these
/// remaps don't take effect; its virtual keyboard is skipped so the two never double up.
///
/// The keyboards' remapping is shared by every user account on the Mac, and macOS loads each
/// account's own keyboard settings when you switch to it, wiping these remaps. So MicFlow only
/// touches it while its account is the one on screen, checks every few seconds that the remaps are
/// still in place, and puts them back right away when you switch back to this account.
final class KeyRemapController {
    enum State: Equatable {
        case off, noKeyboard, karabinerActive, needsAccessibility, running
    }

    var remaps: [KeyRemap] = [] { didSet { apply() } }
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private lazy var languageTap = EventTap(types: [.keyDown, .keyUp]) { [unowned self] type, event in
        self.handleLanguageKey(type, event)
    }
    private var timer: Timer?
    private var appliedServices: [UInt64] = []
    private var sessionObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        // Keyboards forget remaps when they reconnect, and other accounts replace them: re-apply
        // whenever the keyboards change or the remaps aren't what MicFlow set.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, Self.isActiveSession else { return }
            if self.registryIDs(self.keyboards()) != self.appliedServices || !self.mappingIsInPlace() {
                self.apply()
            } else {
                self.updateState()
            }
        }
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Give macOS a moment to load this account's keyboard settings first, then win.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.apply() }
        }
        apply()
    }

    /// Whether this app's account is the one on screen (not switched away from).
    static var isActiveSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    /// Whether every keyboard still has exactly the remaps MicFlow set.
    private func mappingIsInPlace() -> Bool {
        let wanted = Set(remaps.map { "\($0.from)>\($0.to)" })
        for service in keyboards() {
            let current = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [[String: Any]] ?? []
            let pairs = Set(current.compactMap { entry -> String? in
                guard let from = (entry["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value,
                      let to = (entry["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value else { return nil }
                return "\(from)>\(to)"
            })
            if pairs != wanted { return false }
        }
        return true
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let sessionObserver { NSWorkspace.shared.notificationCenter.removeObserver(sessionObserver) }
        sessionObserver = nil
        // Another account on screen owns the keyboards' remapping now: leave theirs alone.
        if Self.isActiveSession {
            for service in keyboards() {
                IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, [] as CFArray)
            }
        }
        languageTap.remove()
        appliedServices = []
        setState(.off)
    }

    private func apply() {
        guard timer != nil, Self.isActiveSession else { return }
        let services = keyboards()
        appliedServices = registryIDs(services)
        let mapping = remaps.map { ["HIDKeyboardModifierMappingSrc": $0.from, "HIDKeyboardModifierMappingDst": $0.to] }
        for service in services {
            IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, mapping as CFArray)
        }
        updateState()
    }

    private func updateState() {
        let needsLanguageTap = remaps.contains { $0.to == KeyChoice.switchLanguage.usage }
        if needsLanguageTap, AXIsProcessTrusted(), languageTap.install() {
            // installed
        } else {
            languageTap.remove()
            if needsLanguageTap, !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
        }
        if appliedServices.isEmpty {
            setState(.noKeyboard)
        } else if karabinerIsActive() {
            setState(.karabinerActive)
        } else if needsLanguageTap, !languageTap.isInstalled {
            setState(.needsAccessibility)
        } else {
            setState(.running)
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    private func allKeyboards() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
    }

    private func isKarabiner(_ service: IOHIDServiceClient) -> Bool {
        (IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String)?.contains("Karabiner") ?? false
    }

    private func keyboards() -> [IOHIDServiceClient] { allKeyboards().filter { !isKarabiner($0) } }

    private func karabinerIsActive() -> Bool { allKeyboards().contains(where: isKarabiner) }

    private func registryIDs(_ services: [IOHIDServiceClient]) -> [UInt64] {
        services.compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value }
    }

    /// F20 (what "Switch input language" keys are mapped to) selects the next input source.
    private func handleLanguageKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_F20) else { return true }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            selectNextInputSource()
        }
        return false
    }

    private func selectNextInputSource() {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                      kTISPropertyInputSourceIsSelectCapable: true,
                      kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              sources.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let ids = sources.map(Self.sourceID)
        let index = ids.firstIndex(of: Self.sourceID(current)) ?? -1
        TISSelectInputSource(sources[(index + 1) % sources.count])
    }

    private static func sourceID(_ source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
