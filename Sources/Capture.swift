import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum CaptureAction: String, CaseIterable, Identifiable {
    case area, previousArea, fullscreen, window, timer, text, record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .previousArea: return "Capture Previous Area"
        case .fullscreen: return "Capture Fullscreen"
        case .window: return "Capture Window"
        case .timer: return "Self-Timer"
        case .text: return "Capture Text (OCR)"
        case .record: return "Record Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .area: return "viewfinder"
        case .previousArea: return "arrow.counterclockwise"
        case .fullscreen: return "display"
        case .window: return "macwindow"
        case .timer: return "timer"
        case .text: return "text.viewfinder"
        case .record: return "record.circle"
        }
    }

    /// At first every shortcut is ⌥⇧⌘ plus a number, next to macOS's own ⇧⌘3, ⇧⌘4 and ⇧⌘5.
    var defaultShortcut: Shortcut {
        let (code, number): (Int, String)
        switch self {
        case .fullscreen: (code, number) = (kVK_ANSI_3, "3")
        case .area: (code, number) = (kVK_ANSI_4, "4")
        case .record: (code, number) = (kVK_ANSI_5, "5")
        case .window: (code, number) = (kVK_ANSI_6, "6")
        case .text: (code, number) = (kVK_ANSI_7, "7")
        case .previousArea: (code, number) = (kVK_ANSI_8, "8")
        case .timer: (code, number) = (kVK_ANSI_9, "9")
        }
        return Shortcut(keyCode: code, modifiers: cmdKey | optionKey | shiftKey, key: number)
    }
}

/// A key with modifiers, e.g. ⌥⇧⌘4. `modifiers` uses Carbon's flags, as hot keys need.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    /// The key's name, e.g. "4" or "F5".
    var key: String

    var text: String {
        var symbols = ""
        if modifiers & controlKey != 0 { symbols += "⌃" }
        if modifiers & optionKey != 0 { symbols += "⌥" }
        if modifiers & shiftKey != 0 { symbols += "⇧" }
        if modifiers & cmdKey != 0 { symbols += "⌘" }
        return symbols + key
    }

    /// From a key press, if it's usable as a shortcut: it needs ⌘, ⌥ or ⌃, unless it's a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        let code = Int(event.keyCode)
        guard carbon & (cmdKey | optionKey | controlKey) != 0 || functionKeys.contains(code) else { return nil }
        // The key as printed on it, not what ⌥ turns it into.
        let printed = event.charactersIgnoringModifiers.flatMap { $0.isEmpty ? nil : $0 }
        self.init(keyCode: code, modifiers: carbon, key: KeyNames.name(Int64(code), characters: printed))
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Screenshots, screen recordings and text capture, like CleanShot X. Every capture is saved in
/// the captures folder; a thumbnail then offers to mark it up, copy it, or upload it for a link.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var shortcutsEnabled: Bool {
        didSet { defaults.set(shortcutsEnabled, forKey: Keys.shortcuts); updateShortcuts() }
    }
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copy) }
    }
    @Published var timerSeconds: Int {
        didSet { defaults.set(timerSeconds, forKey: Keys.timer) }
    }
    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Keys.microphone) }
    }
    /// Each tool's shortcut, by the tool's name; tools not in here use their default.
    @Published private(set) var shortcuts: [String: Shortcut] = [:]
    /// The tool whose new shortcut is being typed.
    @Published private(set) var choosingShortcut: CaptureAction?
    @Published private(set) var shortcutMessage: String?
    private var shortcutMonitor: Any?
    @Published private(set) var isRecording = false
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()

    let imageHost = ImageHost()
    let folder: URL

    private let recorder = ScreenRecorder()
    private let hotKeys = HotKeys()
    private let toast = CaptureToast()
    private let quickAccess = QuickAccessPanel()
    private var recordingIndicator: RecordingIndicator?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let shortcuts = "captureShortcuts", copy = "captureCopyToClipboard", timer = "captureTimerSeconds"
        static let microphone = "captureRecordMicrophone", lastArea = "captureLastArea", shortcutMap = "captureShortcutMap"
    }

    /// The last area captured, for Capture Previous Area.
    private var lastArea: CGRect? {
        get { defaults.string(forKey: Keys.lastArea).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: Keys.lastArea) }
    }

    init() {
        defaults.register(defaults: [Keys.shortcuts: true, Keys.copy: true, Keys.timer: 5, Keys.microphone: false])
        shortcutsEnabled = defaults.bool(forKey: Keys.shortcuts)
        copyToClipboard = defaults.bool(forKey: Keys.copy)
        timerSeconds = defaults.integer(forKey: Keys.timer)
        recordMicrophone = defaults.bool(forKey: Keys.microphone)
        shortcuts = defaults.data(forKey: Keys.shortcutMap).flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        folder = pictures.appendingPathComponent("MicFlow Captures", isDirectory: true)
        moveIfNeeded(from: pictures.appendingPathComponent("Mic Boost Captures", isDirectory: true), to: folder)
        recorder.onStop = { [weak self] in Task { @MainActor in self?.stopRecording() } }
        updateShortcuts()
    }

    func shutDown() {
        hotKeys.removeAll()
    }

    // MARK: Actions

    /// Runs an action from the menu panel: the panel is closed first so it isn't in the picture.
    func perform(_ action: CaptureAction) {
        closeMenuPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.start(action) }
    }

    /// Set while the app is paused by its blocking pop-up.
    var isLocked = false {
        didSet { updateShortcuts() }
    }

    private func start(_ action: CaptureAction) {
        if action == .record, isRecording { return stopRecording() }
        guard !isLocked else { return }
        guard checkScreenPermission() else { return }
        switch action {
        case .area:
            AreaSelector.select(hint: "Drag to capture an area, or click to capture the whole screen. Esc cancels.") { rect in
                if let rect { self.capture(rect) }
            }
        case .previousArea:
            if let lastArea { capture(lastArea) } else { start(.area) }
        case .fullscreen:
            capture(Self.screenUnderPointer.frame)
        case .window:
            captureWindow()
        case .timer:
            countDown(from: timerSeconds) { self.capture(Self.screenUnderPointer.frame, remember: false) }
        case .text:
            AreaSelector.select(hint: "Drag over the text you want to copy. Esc cancels.") { rect in
                if let rect { self.captureText(rect) }
            }
        case .record:
            AreaSelector.select(hint: "Drag to record an area, or click to record the whole screen. Esc cancels.") { rect in
                if let rect { self.startRecording(rect) }
            }
        }
    }

    func openImage() {
        closeMenuPanel()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        annotate(url)
    }

    func openFolder() {
        closeMenuPanel()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: Screenshots

    private func capture(_ rect: CGRect, remember: Bool = true) {
        if remember { lastArea = rect }
        let url = newFile(prefix: "Screenshot", extension: "png")
        Self.screencapture(["-x", "-R", Self.screencaptureRect(rect), url.path]) { ok in
            ok ? self.finished(url) : self.toast.show("Couldn't capture the screen.", isError: true)
        }
    }

    private func captureWindow() {
        let url = newFile(prefix: "Screenshot", extension: "png")
        // macOS's own window picker: hover a window and click it. Esc cancels, leaving no file.
        Self.screencapture(["-x", "-i", "-w", url.path]) { ok in
            if ok { self.finished(url) }
        }
    }

    private func finished(_ url: URL) {
        if copyToClipboard { Self.copyImage(at: url) }
        quickAccess.show(url, actions: actions(for: url))
    }

    private func countDown(from seconds: Int, then capture: @escaping () -> Void) {
        guard seconds > 0 else {
            toast.hide()
            // Gives the countdown time to leave the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: capture)
            return
        }
        toast.show("\(seconds)", isError: false, large: true, duration: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.countDown(from: seconds - 1, then: capture) }
    }

    // MARK: Text

    private func captureText(_ rect: CGRect) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("micboost-ocr-\(UUID().uuidString).png")
        Self.screencapture(["-x", "-R", Self.screencaptureRect(rect), url.path]) { ok in
            defer { try? FileManager.default.removeItem(at: url) }
            guard ok, let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return self.toast.show("Couldn't capture the screen.", isError: true)
            }
            self.copyText(in: image)
        }
    }

    /// Reads the text in an image with macOS's own text recognition (on this Mac, nothing is
    /// uploaded) and copies it.
    func copyText(in image: CGImage) {
        Task {
            let text = await Self.recognizeText(in: image)
            guard !text.isEmpty else { return toast.show("No text found.", isError: true) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let words = text.split(whereSeparator: \.isWhitespace).count
            toast.show("Copied \(words) word\(words == 1 ? "" : "s") of text", isError: false)
        }
    }

    nonisolated static func recognizeText(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    // MARK: Recording

    private func startRecording(_ rect: CGRect) {
        Task {
            var microphone = recordMicrophone
            if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                microphone = false
                toast.show("Recording without sound: MicFlow isn't allowed to use the microphone.", isError: true)
            }
            let url = newFile(prefix: "Recording", extension: "mp4")
            do {
                try await recorder.start(rect: rect, microphone: microphone, to: url)
            } catch {
                return toast.show("Couldn't start recording: \(error.localizedDescription)", isError: true)
            }
            isRecording = true
            let fullScreen = NSScreen.screens.contains { $0.frame == rect }
            recordingIndicator = RecordingIndicator(area: fullScreen ? nil : rect) { [weak self] in self?.stopRecording() }
        }
    }

    func stopRecording(then done: @escaping () -> Void = {}) {
        guard isRecording else { return done() }
        isRecording = false
        recordingIndicator?.remove()
        recordingIndicator = nil
        Task {
            defer { done() }
            guard let url = await recorder.stop() else {
                return toast.show("The recording couldn't be saved.", isError: true)
            }
            quickAccess.show(url, actions: actions(for: url))
        }
    }

    // MARK: After a capture

    private func actions(for url: URL) -> QuickAccessActions {
        let isImage = url.pathExtension.lowercased() == "png"
        return QuickAccessActions(
            annotate: isImage ? { [weak self] in self?.annotate(url) } : nil,
            copy: { [weak self] in
                isImage ? Self.copyImage(at: url) : Self.copyFile(at: url)
                self?.toast.show(isImage ? "Copied" : "Copied the video file", isError: false)
            },
            copyText: isImage ? { [weak self] in
                if let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self?.copyText(in: image)
                }
            } : nil,
            upload: { [weak self] in self?.upload(url) },
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    func annotate(_ url: URL) {
        quickAccess.hide()
        MarkupEditor.open(url, capturesFolder: folder, actions: MarkupEditor.Actions(
            copyText: { [weak self] image in self?.copyText(in: image) },
            upload: { [weak self] url in self?.upload(url) },
            copied: { [weak self] in self?.toast.show("Copied", isError: false) }))
    }

    func upload(_ url: URL) {
        let card = UploadCard(file: url, thumbnail: QuickAccessPanel.thumbnail(of: url))
        Task {
            do {
                let upload = try await imageHost.upload(url) { card.progress($0) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(upload.text, forType: .string)
                card.finished(link: upload.url)
            } catch {
                card.failed(error.localizedDescription)
            }
        }
    }

    // MARK: Helpers

    /// Asks for Screen Recording permission the first time; without it captures only show the
    /// desktop picture.
    private func checkScreenPermission() -> Bool {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        if hasScreenPermission { return true }
        if !CGRequestScreenCaptureAccess() {
            openScreenRecordingSettings()
            toast.show("Turn on MicFlow in Screen Recording settings, then quit and reopen MicFlow.", isError: true, duration: 6)
        }
        return false
    }

    private func updateShortcuts() {
        hotKeys.removeAll()
        guard shortcutsEnabled, choosingShortcut == nil, !isLocked else { return }
        for action in CaptureAction.allCases {
            let shortcut = shortcut(for: action)
            guard shortcut.keyCode >= 0 else { continue }
            hotKeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                self?.start(action)
            }
        }
    }

    // MARK: Changing shortcuts

    func shortcut(for action: CaptureAction) -> Shortcut { shortcuts[action.rawValue] ?? action.defaultShortcut }

    /// Waits for the next key press and makes it `action`'s shortcut. Esc cancels. A shortcut
    /// another tool had is taken from it, and that tool goes back to its default if that's free.
    func chooseShortcut(for action: CaptureAction) {
        cancelChoosingShortcut()
        choosingShortcut = action
        shortcutMessage = nil
        // The current shortcuts are off while typing, so pressing one doesn't take a screenshot.
        hotKeys.removeAll()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.choosingShortcut else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelChoosingShortcut()
                return nil
            }
            guard let new = Shortcut(event: event) else {
                self.shortcutMessage = "Use ⌘, ⌥ or ⌃ with a key (or an F key). Esc cancels."
                return nil
            }
            self.setShortcut(new, for: action)
            self.cancelChoosingShortcut()
            return nil
        }
    }

    func cancelChoosingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        choosingShortcut = nil
        updateShortcuts()
    }

    func resetShortcuts() {
        shortcuts = [:]
        saveShortcuts()
        shortcutMessage = nil
        updateShortcuts()
    }

    private func setShortcut(_ new: Shortcut, for action: CaptureAction) {
        if let other = CaptureAction.allCases.first(where: { $0 != action && shortcut(for: $0) == new }) {
            let fallback = other.defaultShortcut
            let fallbackFree = fallback != new && !CaptureAction.allCases.contains { $0 != other && $0 != action && shortcut(for: $0) == fallback }
            shortcuts[other.rawValue] = fallbackFree ? fallback : Shortcut(keyCode: -1, modifiers: 0, key: "None")
            shortcutMessage = "\(new.text) was \(other.title)'s shortcut, so \(other.title) now uses \(shortcut(for: other).text)."
        }
        shortcuts[action.rawValue] = new
        saveShortcuts()
    }

    private func saveShortcuts() {
        defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Keys.shortcutMap)
    }

    private func newFile(prefix: String, extension ext: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(prefix) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return url
    }

    /// The menu panel closes on its own when the user clicks elsewhere, but not when a button in it
    /// starts a capture.
    private func closeMenuPanel() {
        for window in NSApp.windows where window.isVisible && String(describing: type(of: window)).contains("MenuBarExtra") {
            window.close()
        }
    }

    private static var screenUnderPointer: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `screencapture -R` counts from the top left of the main screen; Cocoa from the bottom left.
    private static func screencaptureRect(_ rect: CGRect) -> String {
        let top = NSScreen.screens[0].frame.maxY - rect.maxY
        return "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
    }

    /// Runs macOS's own `screencapture`; `done` gets whether a file was made.
    private static func screencapture(_ arguments: [String], done: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        let path = arguments.last!
        process.terminationHandler = { _ in
            let made = FileManager.default.fileExists(atPath: path)
            DispatchQueue.main.async { done(made) }
        }
        do { try process.run() } catch { done(false) }
    }

    static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private static func copyFile(at url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}

// MARK: - Shortcuts

/// System-wide keyboard shortcuts. Carbon's hot keys need no Accessibility permission and take the
/// key press, so the app in front doesn't also get it.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D42_4350), id: id)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return }
        refs.append(ref)
        actions[id] = action
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            hotKeys.actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

// MARK: - Messages

/// A short message at the bottom of the screen: "Copied", "Uploading…", a countdown.
@MainActor
final class CaptureToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// `duration: nil` keeps the message up until the next one.
    func show(_ text: String, isError: Bool, large: Bool = false, duration: TimeInterval? = 2.5) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: ToastView(text: text, isError: isError, large: large))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let y = large ? screen.frame.midY - size.height / 2 : screen.visibleFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: y))
        }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct ToastView: View {
    let text: String
    let isError: Bool
    let large: Bool

    var body: some View {
        Text(text)
            .font(large ? .system(size: 64, weight: .semibold).monospacedDigit() : .callout.weight(.medium))
            .foregroundStyle(isError ? Color.red : Color.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: large ? nil : 420)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, large ? 32 : 16)
            .padding(.vertical, large ? 16 : 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: large ? 20 : 12))
    }
}

// MARK: - After a capture

struct QuickAccessActions {
    var annotate: (() -> Void)?
    var copy: () -> Void
    var copyText: (() -> Void)?
    var upload: () -> Void
    var showInFinder: () -> Void
}

/// The thumbnail in the bottom left corner after each capture, with what to do next. It goes away
/// after a while unless the pointer is over it; the capture is already saved either way.
@MainActor
final class QuickAccessPanel {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ url: URL, actions: QuickAccessActions) {
        hide()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let close: () -> Void = { [weak self] in self?.hide() }
        let view = QuickAccessView(url: url, thumbnail: Self.thumbnail(of: url), actions: actions, close: close) { [weak self] hovering in
            if hovering { self?.hideWork?.cancel() } else { self?.scheduleHide() }
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleHide()
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    static func thumbnail(of url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "png" { return NSImage(contentsOf: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map { NSImage(cgImage: $0, size: .zero) }
    }
}

private struct QuickAccessView: View {
    let url: URL
    let thumbnail: NSImage?
    let actions: QuickAccessActions
    let close: () -> Void
    let hovering: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "film").font(.largeTitle).frame(width: 220, height: 120)
                    }
                }
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Drag the thumbnail into any app to drop the file there.
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .onTapGesture { (actions.annotate ?? actions.showInFinder)() }

                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Close")
            }
            HStack(spacing: 4) {
                if let annotate = actions.annotate { button("Mark up", "pencil.tip.crop.circle", annotate) }
                button("Copy", "doc.on.doc", actions.copy)
                if let copyText = actions.copyText { button("Copy text", "text.viewfinder", copyText) }
                button("Upload to GitHub", "icloud.and.arrow.up", actions.upload)
                button("Show in Finder", "folder", actions.showInFinder)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onHover(perform: hovering)
    }

    private func button(_ title: String, _ systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 30, height: 24)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

// MARK: - While recording

/// A stop button in the menu bar with the time so far, and a frame around the area being recorded.
/// MicFlow's own windows are left out of recordings, so neither shows up in the video.
@MainActor
final class RecordingIndicator {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var frame: NSWindow?
    private var timer: Timer?
    private let started = Date()
    private let stop: () -> Void

    init(area: CGRect?, stop: @escaping () -> Void) {
        self.stop = stop
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.toolTip = "Stop recording"
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        if let area { showFrame(around: area) }
    }

    func remove() {
        timer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
        frame?.orderOut(nil)
    }

    @objc private func clicked() { stop() }

    private func update() {
        let seconds = Int(Date().timeIntervalSince(started))
        let title = NSMutableAttributedString(string: "■ ", attributes: [.foregroundColor: NSColor.systemRed])
        title.append(NSAttributedString(string: String(format: "%d:%02d", seconds / 60, seconds % 60),
                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]))
        item.button?.attributedTitle = title
    }

    private func showFrame(around area: CGRect) {
        let window = NSWindow(contentRect: area.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = RecordingFrameView()
        window.orderFrontRegardless()
        frame = window
    }
}

private final class RecordingFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

// MARK: - Uploading

/// A card in the bottom right corner while a capture uploads to GitHub: the file, a progress bar,
/// then "Link copied" (or what went wrong) for a few seconds.
@MainActor
final class UploadCard {
    enum Phase: Equatable {
        /// The share sent so far; nil while connecting.
        case uploading(Double?)
        case finished(link: URL)
        case failed(String)
    }

    /// The card on screen now; a new upload replaces it.
    private static var current: UploadCard?

    private let panel: NSPanel
    private let hosting: NSHostingView<UploadCardView>
    private let file: URL
    private let thumbnail: NSImage?
    private var hideWork: DispatchWorkItem?
    private let started = Date()

    init(file: URL, thumbnail: NSImage?) {
        self.file = file
        self.thumbnail = thumbnail
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hosting = NSHostingView(rootView: UploadCardView(name: file.lastPathComponent, thumbnail: thumbnail,
                                                         phase: .uploading(nil), close: {}))
        panel.contentView = hosting
        Self.current?.close()
        Self.current = self
        update(.uploading(nil))
        // Placed once: the card keeps its corner as its text changes.
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    func progress(_ fraction: Double) {
        update(.uploading(fraction))
    }

    func finished(link: URL) {
        // A screenshot can upload in a blink: leave the progress up long enough to be seen.
        let wait = max(0, 1.2 - Date().timeIntervalSince(started))
        update(.uploading(1))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.update(.finished(link: link))
            self.hide(after: 4)
        }
    }

    func failed(_ message: String) {
        update(.failed(message))
        hide(after: 7)
    }

    private func update(_ phase: Phase) {
        hosting.rootView = UploadCardView(name: file.lastPathComponent, thumbnail: thumbnail, phase: phase) { [weak self] in
            self?.close()
        }
        let origin = panel.frame.origin
        let old = panel.frame.size
        let new = hosting.fittingSize
        // Grows upwards, so the bottom right corner stays put.
        panel.setFrame(CGRect(x: origin.x + old.width - new.width, y: origin.y, width: new.width, height: new.height),
                       display: true)
    }

    private func hide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func close() {
        hideWork?.cancel()
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}

private struct UploadCardView: View {
    let name: String
    let thumbnail: NSImage?
    let phase: UploadCard.Phase
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    icon
                    Text(title).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    Button(action: close) { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close")
                }
                switch phase {
                case .uploading(let fraction):
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                case .finished(let link):
                    Text("Link copied to the clipboard.").font(.caption).foregroundStyle(.secondary)
                    Button("Open in Browser") { NSWorkspace.shared.open(link) }
                        .buttonStyle(.link)
                        .font(.caption)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        switch phase {
        case .uploading: return "Uploading to GitHub…"
        case .finished: return "Uploaded to GitHub"
        case .failed: return "Upload failed"
        }
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .uploading: Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
