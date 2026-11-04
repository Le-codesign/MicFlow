import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Voice typing in the style of Wispr Flow: hold a voice key and speak, release it, and the
/// transcript is pasted into whatever app has focus and left on the clipboard.
/// - Gemini Live streams the recording to Gemini's live transcription while you speak, so the text
///   (English, Bengali, or both mixed, tidied up) is ready about half a second after you let go.
/// - The free Chrome engine uses Chrome's built-in speech recognition, which listens in one
///   language at a time, so it has one key for Bengali and one for English.
@MainActor
final class VoiceTypingModel: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, transcribing
    }

    enum Engine: String, CaseIterable, Identifiable {
        case geminiLive, chrome
        var id: String { rawValue }
        var title: String { self == .geminiLive ? "Model 1 (Recommended)" : "Model 2" }
        /// The short name, for the badge on the Voice page.
        var shortTitle: String { self == .geminiLive ? "Model 1" : "Model 2" }
    }

    /// Which voice key was pressed. With Chrome it's the language to listen in; Gemini Live uses
    /// only the first key and works the language out itself.
    enum VoiceKey {
        case bengali, english
        var language: String { self == .bengali ? "bn-BD" : "en-US" }
    }

    private enum Keys {
        static let enabled = "voiceTypingEnabled"
        static let hotkey = "voiceTypingHotkey"
        static let hotkeyName = "voiceTypingHotkeyName"
        static let englishHotkey = "voiceTypingEnglishHotkey"
        static let englishHotkeyName = "voiceTypingEnglishHotkeyName"
        static let engine = "voiceTypingEngine"
        static let myWords = "voiceTypingMyWords"
        static let mixUps = "voiceTypingMixUps"
        static let fixMixUps = "voiceTypingFixMixUps"
        static let polish = "voiceTypingPolish"
        static let yourInstructions = "voiceTypingYourInstructions"
        static let instructionsEnabled = "voiceTypingInstructionsEnabled"
    }

    /// Presses shorter than this are ignored, so tapping a voice key (e.g. Ctrl in a shortcut) does nothing.
    private static let minimumHold: TimeInterval = 0.3

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); applyEnabled() }
    }
    @Published private(set) var hasKey = KeychainSecret.geminiKey.exists()
    /// The saved key was refused because Google turned off the free plan for its Google account:
    /// Home then asks for a new key (the old one is kept until a new one replaces it).
    @Published private(set) var keyFreePlanOff = UserDefaults.standard.bool(forKey: "keyFreePlanOff")

    private func noteProblem(_ message: String) {
        guard message.contains(ProviderName.freePlanOff), !keyFreePlanOff else { return }
        keyFreePlanOff = true
        UserDefaults.standard.set(true, forKey: "keyFreePlanOff")
    }

    private func keyChanged() {
        keyFreePlanOff = false
        UserDefaults.standard.removeObject(forKey: "keyFreePlanOff")
    }
    /// Gemini Live's key, and Chrome's Bengali key.
    @Published private(set) var hotkey: Int64
    @Published private(set) var hotkeyName: String
    /// Chrome's English key; nil until one is chosen.
    @Published private(set) var englishHotkey: Int64?
    @Published private(set) var englishHotkeyName: String?
    @Published var engine: Engine {
        didSet {
            defaults.set(engine.rawValue, forKey: Keys.engine)
            showingError = false
            if engine == .geminiLive { loadKeyIfNeeded() }
            applyEngine()
            rebuildTap()
            updateStatus()
        }
    }
    /// The user's own words (names, brands, terms), spelled their way in the typed text.
    @Published private(set) var myWords: [String]
    /// Words the user says in a way that comes out as another word; fixed after dictation.
    @Published private(set) var mixUps: [MixUp]
    @Published var fixMixUps: Bool {
        didSet { defaults.set(fixMixUps, forKey: Keys.fixMixUps) }
    }
    /// Whether clean-up uses your instructions.
    @Published var instructionsEnabled: Bool {
        didSet { defaults.set(instructionsEnabled, forKey: Keys.instructionsEnabled) }
    }
    /// Your own instructions for clean-up, added to MicFlow's.
    @Published var yourInstructions: String {
        didSet { defaults.set(yourInstructions, forKey: Keys.yourInstructions) }
    }
    /// Whether the text is cleaned up (punctuation, grammar, filler words, mix-ups) after it's pasted.
    @Published var polish: Bool {
        didSet { defaults.set(polish, forKey: Keys.polish) }
    }
    @Published private(set) var phase = Phase.idle
    /// The key being captured in the panel, if any.
    @Published private(set) var capturing: VoiceKey?
    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var needsAccessibility = false

    /// The device to record from (for Gemini Live), chosen by the Sound tab.
    var inputDevice: () -> AudioDevice? = { nil }
    /// How much louder to make the microphone while dictating (linear).
    var inputGain: () -> Float = { 1 }

    private let defaults = UserDefaults.standard
    private let recorder = VoiceRecorder()
    private let overlay = VoiceOverlay()
    private let pasteStatus = PasteStatus()
    /// Every dictation, for the Home window.
    let log = DictationLog()
    private let chrome = ChromeSpeechBridge()
    private var tap: EventTap?
    private var permissionTimer: Timer?
    private var pressedAt: Date?
    private var pressedKey: VoiceKey?
    private var captureMonitor: Any?
    /// Keeps the last failure on screen until the next dictation or a settings change.
    private var showingError = false

    /// Read from the Keychain once and kept: reading it on every dictation could show a password
    /// box, which blocks the app and makes macOS switch off its key listener.
    private var cachedKey: String?
    private var loadingKey = false
    private var live: LiveTranscriber?
    private var streamTimer: Timer?
    private var sentSamples = 0
    /// Your key presses and clicks, and the dictations pasted, counted to tell whether a pasted text
    /// has been touched before its cleaned-up version arrives.
    private var activity = 0
    private var dictations = 0
    private var activityTap: EventTap?

    private var readyText: String {
        guard engine == .chrome else { return "Hold \(hotkeyName), speak English or Bengali, and let go." }
        guard let englishHotkeyName else { return "Hold \(hotkeyName) and speak Bengali. Choose an English key above for English." }
        return "Hold \(hotkeyName) for Bengali or \(englishHotkeyName) for English, speak, and let go."
    }

    init() {
        defaults.register(defaults: [Keys.enabled: false, Keys.hotkey: Int64(kVK_RightControl), Keys.hotkeyName: "Right Ctrl",
                                     Keys.engine: Engine.geminiLive.rawValue, Keys.fixMixUps: true, Keys.polish: true])
        // Earlier engines: "gemini" (record, then upload) becomes Gemini Live; "whisper" became Chrome.
        let savedEngine = defaults.string(forKey: Keys.engine) ?? ""
        engine = savedEngine == "gemini" ? .geminiLive : savedEngine == "whisper" ? .chrome : Engine(rawValue: savedEngine) ?? .geminiLive
        enabled = defaults.bool(forKey: Keys.enabled)
        hotkey = (defaults.object(forKey: Keys.hotkey) as? NSNumber)?.int64Value ?? Int64(kVK_RightControl)
        hotkeyName = defaults.string(forKey: Keys.hotkeyName) ?? "Right Ctrl"
        englishHotkey = (defaults.object(forKey: Keys.englishHotkey) as? NSNumber)?.int64Value
        englishHotkeyName = defaults.string(forKey: Keys.englishHotkeyName)
        myWords = defaults.stringArray(forKey: Keys.myWords) ?? []
        mixUps = defaults.data(forKey: Keys.mixUps).flatMap { try? JSONDecoder().decode([MixUp].self, from: $0) } ?? []
        fixMixUps = defaults.bool(forKey: Keys.fixMixUps)
        polish = defaults.bool(forKey: Keys.polish)
        yourInstructions = defaults.string(forKey: Keys.yourInstructions) ?? ""
        instructionsEnabled = defaults.object(forKey: Keys.instructionsEnabled) as? Bool ?? true
        // Both engines use the key for the clean-up.
        loadKeyIfNeeded()
        overlay.level = { [recorder] in recorder.level }
        applyEnabled()
    }

    // MARK: Settings

    /// Reads the saved key once, then saves it again so this build of the app owns the Keychain item
    /// and later launches can read it without asking.
    /// Reads the key from the Keychain in the background: macOS may ask you to allow it first, and
    /// MicFlow must keep working while that question is up.
    private func loadKeyIfNeeded() {
        guard cachedKey == nil, hasKey, !loadingKey else { return }
        loadingKey = true
        Task.detached {
            let key = KeychainSecret.geminiKey.load()
            // Saved again so it's stored for this build of MicFlow and macOS stops asking.
            if let key { KeychainSecret.geminiKey.save(key) }
            await MainActor.run {
                self.loadingKey = false
                if let key, self.cachedKey == nil { self.cachedKey = key }
            }
        }
    }

    /// Checks the key and saves it; returns why it was refused, or nil when it's saved.
    func saveKeyChecked(_ key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // A brand-new key can take a few seconds to start working.
            var lastError: Error?
            for attempt in 0..<4 {
                do { try await GeminiClient.check(key: key); lastError = nil; break } catch { lastError = error }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
            if let lastError { throw lastError }
            KeychainSecret.geminiKey.save(key)
            cachedKey = key
            hasKey = true
            keyChanged()
            showingError = false
            updateStatus()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            showingError = false
            setStatus("Checking your key…")
            do {
                try await GeminiClient.check(key: key)
                KeychainSecret.geminiKey.save(key)
                cachedKey = key
                hasKey = true
                keyChanged()
                updateStatus()
            } catch {
                showingError = true
                setStatus("That key didn't work: \(error.localizedDescription)", error: true)
            }
        }
    }

    /// What's saved to your account when you're signed in. The API key never is: it stays in this
    /// Mac's Keychain only, so nobody but this Mac can see or use it.
    func savedPreferences() -> SavedPreferences {
        SavedPreferences(instructions: yourInstructions, instructions_enabled: instructionsEnabled,
                         my_words: myWords, mix_ups: mixUps, api_key: nil)
    }

    /// Brings back what your account has: words and mix-ups are added to the ones here, and the
    /// account's instructions and API key are used if it has them.
    func apply(_ saved: SavedPreferences) {
        if !saved.instructions.isEmpty { yourInstructions = saved.instructions }
        instructionsEnabled = saved.instructions_enabled
        for word in saved.my_words { addWord(word) }
        for mixUp in saved.mix_ups where !mixUps.contains(where: { $0.heard == mixUp.heard && $0.meant == mixUp.meant }) {
            mixUps.append(mixUp)
        }
        saveMixUps()
        if let key = saved.api_key, !key.isEmpty, key != cachedKey {
            KeychainSecret.geminiKey.save(key)
            cachedKey = key
            hasKey = true
            keyChanged()
            updateStatus()
        }
    }

    func removeKey() {
        showingError = false
        KeychainSecret.geminiKey.delete()
        cachedKey = nil
        hasKey = false
        keyChanged()
        updateStatus()
    }

    // MARK: Personal dictionary

    func addWord(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !myWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        myWords.append(word)
        defaults.set(myWords, forKey: Keys.myWords)
    }

    func removeWord(_ word: String) {
        myWords.removeAll { $0 == word }
        defaults.set(myWords, forKey: Keys.myWords)
    }

    func addMixUp(heard: String, meant: String, meaning: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard.caseInsensitiveCompare(meant) != .orderedSame else { return }
        mixUps.append(MixUp(heard: heard, meant: meant, meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines)))
        saveMixUps()
    }

    func removeMixUp(_ mixUp: MixUp) {
        mixUps.removeAll { $0.id == mixUp.id }
        saveMixUps()
    }

    private func saveMixUps() {
        defaults.set(try? JSONEncoder().encode(mixUps), forKey: Keys.mixUps)
    }

    /// Waits for the next key press in the panel and makes it that voice key.
    func captureHotkey(_ key: VoiceKey) {
        stopCapture()
        capturing = key
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let code = Int64(event.keyCode)
            // A modifier counts when it goes down, not when it's released.
            if event.type == .flagsChanged {
                guard KeyNames.modifierFlags[code] != nil,
                      KeyNames.isDown(code, in: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) else { return event }
            }
            self.setHotkey(key, code, name: KeyNames.name(code, characters: event.type == .keyDown ? event.charactersIgnoringModifiers : nil))
            return nil
        }
    }

    func cancelCapture() { stopCapture() }

    private func setHotkey(_ key: VoiceKey, _ code: Int64, name: String) {
        switch key {
        case .bengali:
            hotkey = code
            hotkeyName = name
            defaults.set(code, forKey: Keys.hotkey)
            defaults.set(name, forKey: Keys.hotkeyName)
            // One key can't mean both languages.
            if englishHotkey == code { clearEnglishHotkey() }
        case .english:
            guard code != hotkey else {
                stopCapture()
                showingError = true
                setStatus("\(name) is already the Bengali key. Pick a different key for English.", error: true)
                return
            }
            englishHotkey = code
            englishHotkeyName = name
            defaults.set(code, forKey: Keys.englishHotkey)
            defaults.set(name, forKey: Keys.englishHotkeyName)
        }
        stopCapture()
        showingError = false
        rebuildTap()
        updateStatus()
    }

    private func clearEnglishHotkey() {
        englishHotkey = nil
        englishHotkeyName = nil
        defaults.removeObject(forKey: Keys.englishHotkey)
        defaults.removeObject(forKey: Keys.englishHotkeyName)
    }

    private func stopCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        capturing = nil
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Running

    func shutDown() {
        cancelRecording()
        tap?.remove()
        activityTap?.remove()
        chrome.stop()
    }

    /// Opens MicFlow's voice typing page in Chrome (in the background) if it isn't open already.
    func openChromePage() {
        chrome.start()
        chrome.openPageIfNeeded()
    }

    /// Chrome's page bridge only runs while voice typing is on with Chrome chosen.
    private func applyEngine() {
        if enabled, engine == .chrome { chrome.start() } else { chrome.stop() }
    }

    /// The voice keys in use for the current engine.
    private var activeKeys: [(VoiceKey, Int64)] {
        var keys: [(VoiceKey, Int64)] = [(.bengali, hotkey)]
        if engine == .chrome, let englishHotkey { keys.append((.english, englishHotkey)) }
        return keys
    }

    /// When every voice key is a modifier (Ctrl, Option…), the tap only listens, so keystrokes in
    /// other apps never wait for MicFlow. Other keys have to be held back so they don't type.
    private func rebuildTap() {
        tap?.remove()
        tap = nil
        guard enabled else { return }
        let listenOnly = activeKeys.allSatisfy { KeyNames.modifierFlags[$0.1] != nil }
        tap = EventTap(types: [.flagsChanged, .keyDown, .keyUp], listenOnly: listenOnly) { [unowned self] type, event in
            MainActor.assumeIsolated { self.handleKey(type, event) }
        }
        activityTap?.remove()
        activityTap = EventTap(types: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], listenOnly: true) { [unowned self] _, event in
            if event.getIntegerValueField(.eventSourceUserData) != PastedText.syntheticMarker {
                MainActor.assumeIsolated { self.activity += 1 }
            }
            return true
        }
        updateStatus()
    }

    /// What's missing before this engine can type, if anything.
    private var engineProblem: String? {
        switch engine {
        case .geminiLive:
            return hasKey ? nil : "Add your API key in the API key card to start, or click Set it up for me."
        case .chrome:
            if !chrome.chromeInstalled { return "Model 2 needs Google Chrome installed." }
            return chrome.isConnected ? nil : "Waiting for the MicFlow tab in Chrome. Click \"Open the Model 2 tab\" below."
        }
    }

    private func applyEnabled() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        applyEngine()
        rebuildTap()
        guard enabled else {
            cancelRecording()
            setStatus("")
            return
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Re-checks until Accessibility is granted, and notices Chrome's tab connecting or closing.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    private func updateStatus() {
        guard enabled, let tap else { return }
        needsAccessibility = !(AXIsProcessTrusted() && tap.install())
        if !needsAccessibility { activityTap?.install() }
        if needsAccessibility {
            tap.remove()
            setStatus("Voice typing needs Accessibility permission to hear the voice keys and type the text.", error: true)
        } else if showingError {
            // Leave the last error up.
        } else if let problem = engineProblem {
            setStatus(problem, error: true)
        } else if phase == .idle {
            setStatus(readyText)
        }
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func handleKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let (voiceKey, keyCode) = activeKeys.first(where: { $0.1 == code }) else {
            // Another key while holding a modifier voice key means a shortcut like Ctrl+C, not dictation.
            if type == .keyDown, pressedAt != nil, let pressed = pressedKey,
               KeyNames.modifierFlags[pressed == .bengali ? hotkey : englishHotkey ?? -1] != nil {
                cancelRecording()
            }
            return true
        }
        if KeyNames.modifierFlags[keyCode] != nil {
            // Modifier voice key: watch it go down and up, and let it through so shortcuts still work.
            if type == .flagsChanged {
                KeyNames.isDown(keyCode, in: event.flags) ? keyDown(voiceKey) : keyUp(voiceKey)
            }
            return true
        }
        guard type == .keyDown || type == .keyUp else { return true }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { keyDown(voiceKey) }
        } else {
            keyUp(voiceKey)
        }
        return false
    }

    /// Set while the app is paused by its blocking pop-up.
    var isLocked = false

    /// A problem when the key is pressed, shown on the Voice page and, since you're usually in
    /// another app, at the bottom of the screen for a few seconds.
    private func startProblem(_ message: String) {
        noteProblem(message)
        showingError = true
        setStatus(message, error: true)
        overlay.show(.failed(message))
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle, self.status == shown else { return }
                self.overlay.hide()
            }
        }
    }

    private func keyDown(_ key: VoiceKey) {
        guard phase == .idle, pressedAt == nil, !isLocked else { return }
        switch engine {
        case .chrome:
            guard chrome.isConnected else {
                chrome.openPageIfNeeded()
                startProblem("Open the MicFlow tab in Chrome (it just opened) and allow the microphone, then try again.")
                return
            }
            chrome.beginListening(language: key.language)
            // Chrome does the listening; MicFlow records only to show the waveform.
            if let input = inputDevice() { try? recorder.start(input, gain: inputGain()) }
        case .geminiLive:
            guard let cachedKey else {
                if hasKey {
                    loadKeyIfNeeded()
                    startProblem("Getting your API key from the Keychain. If macOS asks, click Always Allow, then try again.")
                } else {
                    startProblem("Voice typing needs to be set up first: open MicFlow, and Home shows the two ways (about a minute).")
                }
                return
            }
            guard let input = inputDevice() else {
                startProblem("No microphone found. Pick one in MicFlow › Sound.")
                return
            }
            do {
                try recorder.start(input, gain: inputGain())
            } catch {
                startProblem(error.localizedDescription)
                return
            }
            let live = GeminiLiveTranscriber(key: cachedKey, inputRate: recorder.sampleRate)
            live.onText = { [weak self] text in self?.overlay.show(.listening(text)) }
            self.live = live
            sentSamples = 0
            // Sends what's been recorded every 0.1 s, while the key is held.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.streamNewAudio() }
            }
            RunLoop.main.add(timer, forMode: .common)
            streamTimer = timer
        }
        if polish, let cachedKey { Polisher.warmUp(key: cachedKey) }
        pressedAt = Date()
        pressedKey = key
        phase = .listening
        overlay.show(.listening(""))
    }

    private func streamNewAudio() {
        guard let live else { return }
        let new = recorder.samples(from: sentSamples)
        sentSamples += new.count
        live.append(new, sampleRate: recorder.sampleRate)
    }

    private func keyUp(_ key: VoiceKey) {
        guard phase == .listening, let pressedAt, pressedKey == key else { return }
        guard Date().timeIntervalSince(pressedAt) >= Self.minimumHold else {
            cancelRecording()
            return
        }
        let heldFor = Date().timeIntervalSince(pressedAt)
        self.pressedAt = nil
        pressedKey = nil
        phase = .transcribing
        overlay.show(.transcribing)
        showingError = false
        let engine = self.engine

        // Gemini Live: stop recording and hand over the audio not sent yet.
        var lastSamples: [Float] = []
        let live = self.live
        if engine == .chrome { _ = recorder.stop() }
        if engine == .geminiLive {
            streamTimer?.invalidate()
            streamTimer = nil
            let all = recorder.stop()
            lastSamples = sentSamples < all.count ? Array(all[sentSamples...]) : []
            self.live = nil
        }
        Task {
            do {
                var text: String
                var settled = true
                if engine == .chrome {
                    guard let heard = await chrome.finishListening(), !heard.isEmpty else {
                        throw GeminiClient.Failure(message: "Model 2 didn't hear anything. Check the microphone setting in Chrome.")
                    }
                    text = heard
                } else {
                    guard let live else { throw GeminiClient.Failure(message: "Model 1 didn't start.") }
                    // What's been heard within about a second of letting go; any last words follow.
                    text = try await live.finish(lastSamples)
                    // The popup closes now; words arriving later go only into the pasted text.
                    live.onText = { _ in }
                    if text.isEmpty { text = await live.settle() } else { settled = false }
                }
                let raw = MyWords.spell(text, myWords)
                overlay.hide()
                setStatus(readyText)
                phase = .idle
                guard !raw.isEmpty else { return }
                // Pasted as heard right away; the full, cleaned-up version replaces it when it's back.
                dictations += 1
                let pasted = PastedText.paste(raw, activity: activity, dictation: dictations)
                loadKeyIfNeeded()
                let willPolish = polish && cachedKey != nil
                // Esc while "Further polishing…" shows stops here and keeps the pasted text.
                var cancelled = false
                let work = Task { () -> String in
                    var full = raw
                    if !settled, let live {
                        let settledText = MyWords.spell(await live.settle(), myWords)
                        if !settledText.isEmpty { full = settledText }
                    }
                    guard willPolish, !Task.isCancelled, let cachedKey,
                          let polished = await Polisher.polish(full, mixUps: fixMixUps ? mixUps : [],
                                                               yourInstructions: instructionsEnabled ? yourInstructions : "",
                                                               key: cachedKey, timeLimit: 2) else { return full }
                    return MyWords.spell(polished, myWords)
                }
                let statusID = pasteStatus.pasted(polishing: willPolish) {
                    cancelled = true
                    work.cancel()
                    if let live { live.cancel() }
                    voiceLog.info("Clean-up cancelled with Esc")
                }
                let final = await work.value
                pasteStatus.done(statusID)
                guard !cancelled else {
                    log.add(pasted.text, seconds: heldFor)
                    return
                }
                guard final != pasted.text else {
                    log.add(final, seconds: heldFor)
                    return
                }
                let outcome = pasted.replace(with: final, activityNow: activity, dictationNow: dictations)
                voiceLog.info("Cleaned-up text \(outcome.rawValue, privacy: .public)")
                // The clipboard always gets the final words, unless you've copied something since.
                if NSPasteboard.general.changeCount == pasted.clipboardChange {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                }
                log.add(final, seconds: heldFor)
                return
            } catch {
                overlay.show(.failed(error.localizedDescription))
                noteProblem(error.localizedDescription)
                showingError = true
                setStatus("Couldn't transcribe: \(error.localizedDescription)", error: true)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                overlay.hide()
            }
            phase = .idle
        }
    }

    private func cancelRecording() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        pressedKey = nil
        chrome.cancelListening()
        streamTimer?.invalidate()
        streamTimer = nil
        live?.cancel()
        live = nil
        _ = recorder.stop()
        phase = .idle
        overlay.hide()
    }
}
