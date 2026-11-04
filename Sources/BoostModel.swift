import Combine
import AVFoundation
import CoreAudio
import ServiceManagement
import SwiftUI

@MainActor
final class BoostModel: ObservableObject {
    private enum Keys {
        static let enabled = "enabled"
        static let micUID = "micUID"
        static let gainDB = "gainDB"
        static let maxHardwareVolume = "maxHardwareVolume"
        static let speakerEnabled = "speakerEnabled"
        static let speakerUID = "speakerUID"
        static let speakerGainDB = "speakerGainDB"
        static let middleClickEnabled = "middleClickEnabled"
        static let middleZoneWidth = "middleZoneWidth"
        static let figmaZoomEnabled = "figmaZoomEnabled"
        static let figmaZoomAmount = "figmaZoomAmount"
        static let scrollDistanceEnabled = "scrollDistanceEnabled"
        static let scrollDistance = "scrollDistance"
        static let smoothScrollEnabled = "smoothScrollEnabled"
        static let scrollSmoothness = "scrollSmoothness"
        static let trackingSpeedEnabled = "trackingSpeedEnabled"
        static let trackingLevel = "trackingLevel"
        static let swipeEnabled = "swipeEnabled"
        static let swipeLeftAction = "swipeLeftAction"
        static let swipeRightAction = "swipeRightAction"
        static let mouseButtonsEnabled = "mouseButtonsEnabled"
        static let mouseButtonActions = "mouseButtonActions"
        static let buttonMappings = "mouseButtonMappings"
        static let keyRemapEnabled = "keyRemapEnabled"
        static let keyRemaps = "keyRemaps"
        static let loginItemConfigured = "loginItemConfigured"
        static let boostRangeRaised = "boostRangeRaised"
    }

    static let maxGainDB = 30.0

    @Published private(set) var micDevices: [AudioDevice] = []
    @Published private(set) var speakerDevices: [AudioDevice] = []
    /// BlackHole 2ch: boosted mic audio goes in here, and other apps record from it.
    @Published private(set) var micVirtual: AudioDevice?
    /// BlackHole 16ch: the Mac's default output while speaker boost is on; its sound is boosted from here.
    @Published private(set) var speakerVirtual: AudioDevice?

    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var isRunning = false
    @Published private(set) var needsMicPermission = false

    @Published private(set) var speakerStatus = ""
    @Published private(set) var speakerStatusIsError = false
    @Published private(set) var speakerRunning = false

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); applyState() }
    }
    @Published var selectedMicUID: String {
        didSet {
            guard selectedMicUID != oldValue else { return }
            defaults.set(selectedMicUID, forKey: Keys.micUID)
            applyState()
        }
    }
    @Published var gainDB: Double {
        didSet { micEngine.targetGain = Self.linear(gainDB); defaults.set(gainDB, forKey: Keys.gainDB) }
    }
    @Published var maxHardwareVolume: Bool {
        didSet {
            defaults.set(maxHardwareVolume, forKey: Keys.maxHardwareVolume)
            if maxHardwareVolume, let mic = selectedMic { CA.setInputVolumeToMax(mic.id) }
        }
    }
    @Published var speakerEnabled: Bool {
        didSet { defaults.set(speakerEnabled, forKey: Keys.speakerEnabled); applySpeakerState() }
    }
    @Published var selectedSpeakerUID: String {
        didSet {
            guard selectedSpeakerUID != oldValue else { return }
            defaults.set(selectedSpeakerUID, forKey: Keys.speakerUID)
            applySpeakerState()
        }
    }
    @Published var speakerGainDB: Double {
        didSet { speakerEngine.targetGain = Self.linear(speakerGainDB); defaults.set(speakerGainDB, forKey: Keys.speakerGainDB) }
    }
    @Published private(set) var middleClickState = MiddleClickController.State.off

    @Published var middleClickEnabled: Bool {
        didSet {
            defaults.set(middleClickEnabled, forKey: Keys.middleClickEnabled)
            middleClickEnabled ? middleClick.start() : middleClick.stop()
        }
    }
    /// Width of the Magic Mouse's middle-click area, as a fraction of the mouse's width.
    @Published var middleZoneWidth: Double {
        didSet { middleClick.zoneWidth = Float(middleZoneWidth); defaults.set(middleZoneWidth, forKey: Keys.middleZoneWidth) }
    }
    @Published private(set) var figmaZoomState = FigmaZoomController.State.off

    @Published var figmaZoomEnabled: Bool {
        didSet {
            defaults.set(figmaZoomEnabled, forKey: Keys.figmaZoomEnabled)
            figmaZoomEnabled ? figmaZoom.start() : figmaZoom.stop()
        }
    }
    /// Multiplier on how far each swipe zooms in Figma, 1 = Figma's normal.
    @Published var figmaZoomAmount: Double {
        didSet { figmaZoom.zoomAmount = figmaZoomAmount; defaults.set(figmaZoomAmount, forKey: Keys.figmaZoomAmount) }
    }

    @Published private(set) var scrollState = ScrollController.State.off

    @Published var scrollDistanceEnabled: Bool {
        didSet { defaults.set(scrollDistanceEnabled, forKey: Keys.scrollDistanceEnabled); applyScrolling() }
    }
    /// Multiplier on how far each swipe scrolls, 1 = macOS normal.
    @Published var scrollDistance: Double {
        didSet { defaults.set(scrollDistance, forKey: Keys.scrollDistance); applyScrolling() }
    }
    @Published var smoothScrollEnabled: Bool {
        didSet { defaults.set(smoothScrollEnabled, forKey: Keys.smoothScrollEnabled); applyScrolling() }
    }
    /// 0 = light smoothing, 1 = very smooth.
    @Published var scrollSmoothness: Double {
        didSet { scrolling.smoothness = scrollSmoothness; defaults.set(scrollSmoothness, forKey: Keys.scrollSmoothness) }
    }

    @Published private(set) var trackingState = TrackingSpeedController.State.off

    @Published var trackingSpeedEnabled: Bool {
        didSet {
            defaults.set(trackingSpeedEnabled, forKey: Keys.trackingSpeedEnabled)
            trackingSpeedEnabled ? tracking.start() : tracking.stop()
        }
    }
    /// macOS's Tracking speed value, from 3 (macOS's Fast) up to 7.8.
    @Published var trackingSpeed: Double {
        didSet { tracking.speed = trackingSpeed; defaults.set(trackingSpeed, forKey: Keys.trackingLevel) }
    }

    @Published private(set) var swipeState = SwipeGestureController.State.off

    @Published var swipeEnabled: Bool {
        didSet {
            defaults.set(swipeEnabled, forKey: Keys.swipeEnabled)
            swipeEnabled ? swipes.start() : swipes.stop()
        }
    }
    @Published var swipeLeftAction: SwipeGestureController.Action {
        didSet { swipes.leftAction = swipeLeftAction; defaults.set(swipeLeftAction.rawValue, forKey: Keys.swipeLeftAction); swipes.update() }
    }
    @Published var swipeRightAction: SwipeGestureController.Action {
        didSet { swipes.rightAction = swipeRightAction; defaults.set(swipeRightAction.rawValue, forKey: Keys.swipeRightAction); swipes.update() }
    }

    @Published private(set) var mouseButtonsState = MouseButtonController.State.off

    @Published var mouseButtonsEnabled: Bool {
        didSet {
            defaults.set(mouseButtonsEnabled, forKey: Keys.mouseButtonsEnabled)
            mouseButtonsEnabled ? mouseButtons.start() : mouseButtons.stop()
        }
    }
    @Published var mouseButtonActions: [MouseButtonController.Trigger: MouseAction] {
        didSet {
            mouseButtons.actions = mouseButtonActions
        mouseButtons.mappings = buttonMappings
        MouseAction.capture = { [weak self] action in self?.capture.perform(action) }
            defaults.set(Dictionary(uniqueKeysWithValues: mouseButtonActions.map { ($0.key.rawValue, $0.value.rawValue) }),
                         forKey: Keys.mouseButtonActions)
        }
    }

    /// Mouse buttons you added, and what each does.
    @Published var buttonMappings: [ButtonMapping] {
        didSet {
            mouseButtons.mappings = buttonMappings
            defaults.set(try? JSONEncoder().encode(buttonMappings), forKey: Keys.buttonMappings)
        }
    }
    /// True while waiting for you to press the mouse button to add.
    @Published private(set) var waitingForButton = false
    /// The added button whose own keyboard shortcut is being typed.
    @Published private(set) var choosingKeysFor: Int64?
    private var keysMonitor: Any?

    /// Waits for the next extra mouse button you press, then adds it (set to do nothing yet).
    func addMouseButton() {
        if !mouseButtonsEnabled { mouseButtonsEnabled = true }
        waitingForButton = true
        mouseButtons.onButtonRecorded = { [weak self] button in
            guard let self else { return }
            self.waitingForButton = false
            if !self.buttonMappings.contains(where: { $0.button == button }) {
                self.buttonMappings.append(ButtonMapping(button: button, action: .none, shortcut: nil))
            }
        }
    }

    func cancelAddingMouseButton() {
        mouseButtons.onButtonRecorded = nil
        waitingForButton = false
    }

    func setAction(_ action: MouseAction, forButton button: Int64) {
        guard let index = buttonMappings.firstIndex(where: { $0.button == button }) else { return }
        buttonMappings[index].action = action
        if action == .customShortcut { chooseKeys(forButton: button) }
    }

    func removeMouseButton(_ button: Int64) {
        buttonMappings.removeAll { $0.button == button }
    }

    /// Waits for a key press with ⌘, ⌥ or ⌃ (or an F key) to send when the button is pressed.
    func chooseKeys(forButton button: Int64) {
        stopChoosingKeys()
        choosingKeysFor = button
        keysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let button = self.choosingKeysFor else { return event }
            if event.keyCode == 53 { self.stopChoosingKeys(); return nil }
            guard let shortcut = Shortcut(event: event),
                  let index = self.buttonMappings.firstIndex(where: { $0.button == button }) else { return nil }
            self.buttonMappings[index].shortcut = shortcut
            self.stopChoosingKeys()
            return nil
        }
    }

    func stopChoosingKeys() {
        if let keysMonitor { NSEvent.removeMonitor(keysMonitor) }
        keysMonitor = nil
        choosingKeysFor = nil
    }

    @Published private(set) var keyRemapState = KeyRemapController.State.off

    @Published var keyRemapEnabled: Bool {
        didSet {
            defaults.set(keyRemapEnabled, forKey: Keys.keyRemapEnabled)
            keyRemapEnabled ? keyRemapper.start() : keyRemapper.stop()
        }
    }
    @Published var keyRemaps: [KeyRemap] {
        didSet {
            keyRemapper.remaps = keyRemaps
            defaults.set(try? JSONEncoder().encode(keyRemaps), forKey: Keys.keyRemaps)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    let voiceTyping = VoiceTypingModel()
    let capture = CaptureModel()
    let micEngine = BoostEngine()
    let speakerEngine = BoostEngine()
    private let middleClick = MiddleClickController()
    private let figmaZoom = FigmaZoomController()
    private let scrolling = ScrollController()
    private let tracking = TrackingSpeedController()
    private let swipes = SwipeGestureController()
    private let mouseButtons = MouseButtonController()
    private let keyRemapper = KeyRemapController()
    /// True while your blocking pop-up is up: every feature is paused, settings stay as they are.
    @Published private(set) var locked = false

    /// Starts Google sign-in, when sign-in is set up.
    var signInAction: (() -> Void)? { account.isConfigured ? { [weak self] in self?.account.signIn(setUpKey: false) } : nil }

    /// Shows or lifts your blocking pop-up from the CMS. Your admin build is never blocked, so you
    /// can always turn it off.
    func evaluateLock() {
        #if ADMIN
        setLocked(false)
        #else
        guard let blocker = siteContent.content.block, blocker.enabled else { return setLocked(false) }
        let met: Bool
        switch blocker.condition {
        case .always: met = false
        case .update: met = blocker.minimumVersion.map { !Updater.isNewer($0, than: updater.currentVersion) } ?? true
        case .signIn: met = account.isSignedIn
        }
        setLocked(!met)
        #endif
    }

    func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        voiceTyping.isLocked = value
        capture.isLocked = value
        if value {
            [middleClick.stop, figmaZoom.stop, tracking.stop, swipes.stop, mouseButtons.stop, keyRemapper.stop].forEach { $0() }
            scrolling.stop()
        } else {
            if middleClickEnabled { middleClick.start() }
            if figmaZoomEnabled { figmaZoom.start() }
            if trackingSpeedEnabled { tracking.start() }
            if swipeEnabled { swipes.start() }
            if mouseButtonsEnabled { mouseButtons.start() }
            if keyRemapEnabled { keyRemapper.start() }
            applyScrolling()
        }
        applyState()
        applySpeakerState()
    }

    /// The About page and posts in Settings, and new versions of MicFlow.
    let siteContent = SiteContentStore()
    let updater = Updater()
    /// The optional Google account: preferences, API key and feature requests.
    let account = Account()
    lazy var featureRequests = FeatureRequestStore(account: account)
    private var contentWatch: AnyCancellable?
    private var accountWatch: AnyCancellable?
    private var contentTimer: Timer?
    private var prefsWatch: AnyCancellable?
    private var lastSavedPreferences: Data?

    /// Saves your preferences to your account; right after signing in, first brings back what the
    /// account already has.
    func syncPreferences(loadFirst: Bool) {
        guard account.isSignedIn else { return }
        Task {
            do {
                if loadFirst, let saved = try await PreferenceSync.load(account) { voiceTyping.apply(saved) }
                let current = voiceTyping.savedPreferences()
                let encoded = try JSONEncoder().encode(current)
                guard encoded != lastSavedPreferences else { return }
                try await PreferenceSync.save(current, account: account)
                lastSavedPreferences = encoded
            } catch {
                voiceLog.info("Saving preferences failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    private let defaults = UserDefaults.standard

    /// The saved mic if it's connected, else the system default input, else the first mic found.
    var selectedMic: AudioDevice? {
        micDevices.first { $0.uid == selectedMicUID }
            ?? CA.defaultInputDevice().flatMap { id in micDevices.first { $0.id == id } }
            ?? micDevices.first
    }

    /// The saved speakers if connected, else the system default output, else the first output found.
    var selectedSpeaker: AudioDevice? {
        speakerDevices.first { $0.uid == selectedSpeakerUID }
            ?? CA.defaultOutputDevice().flatMap { id in speakerDevices.first { $0.id == id } }
            ?? speakerDevices.first
    }

    init() {
        defaults.register(defaults: [Keys.enabled: false, Keys.gainDB: 30.0, Keys.maxHardwareVolume: true,
                                     Keys.speakerEnabled: true, Keys.speakerGainDB: 6.0,
                                     Keys.middleClickEnabled: false, Keys.middleZoneWidth: 0.3,
                                     Keys.figmaZoomEnabled: false, Keys.figmaZoomAmount: 1.0,
                                     Keys.scrollDistanceEnabled: false, Keys.scrollDistance: 1.0,
                                     Keys.smoothScrollEnabled: false, Keys.scrollSmoothness: 0.5,
                                     Keys.trackingSpeedEnabled: false, Keys.trackingLevel: TrackingSpeedController.macOSFast,
                                     Keys.swipeEnabled: false,
                                     Keys.swipeLeftAction: SwipeGestureController.Action.moveRightSpace.rawValue,
                                     Keys.swipeRightAction: SwipeGestureController.Action.moveLeftSpace.rawValue,
                                     Keys.mouseButtonsEnabled: false,
                                     Keys.keyRemapEnabled: false])
        enabled = defaults.bool(forKey: Keys.enabled)
        selectedMicUID = defaults.string(forKey: Keys.micUID) ?? ""
        // The slider used to stop at +20 dB: someone who had it at the top gets the new top.
        if !defaults.bool(forKey: Keys.boostRangeRaised) {
            defaults.set(true, forKey: Keys.boostRangeRaised)
            if defaults.object(forKey: Keys.gainDB) != nil, defaults.double(forKey: Keys.gainDB) >= 20 {
                defaults.set(Self.maxGainDB, forKey: Keys.gainDB)
            }
        }
        gainDB = min(max(defaults.double(forKey: Keys.gainDB), 0), Self.maxGainDB)
        maxHardwareVolume = defaults.bool(forKey: Keys.maxHardwareVolume)
        speakerEnabled = defaults.bool(forKey: Keys.speakerEnabled)
        selectedSpeakerUID = defaults.string(forKey: Keys.speakerUID) ?? ""
        speakerGainDB = min(max(defaults.double(forKey: Keys.speakerGainDB), 0), Self.maxGainDB)
        middleClickEnabled = defaults.bool(forKey: Keys.middleClickEnabled)
        middleZoneWidth = min(max(defaults.double(forKey: Keys.middleZoneWidth), 0.15), 0.5)
        figmaZoomEnabled = defaults.bool(forKey: Keys.figmaZoomEnabled)
        figmaZoomAmount = min(max(defaults.double(forKey: Keys.figmaZoomAmount), 0.25), 4)
        scrollDistanceEnabled = defaults.bool(forKey: Keys.scrollDistanceEnabled)
        scrollDistance = min(max(defaults.double(forKey: Keys.scrollDistance), 0.25), 4)
        smoothScrollEnabled = defaults.bool(forKey: Keys.smoothScrollEnabled)
        scrollSmoothness = min(max(defaults.double(forKey: Keys.scrollSmoothness), 0), 1)
        trackingSpeedEnabled = defaults.bool(forKey: Keys.trackingSpeedEnabled)
        trackingSpeed = min(max(defaults.double(forKey: Keys.trackingLevel), TrackingSpeedController.macOSFast),
                            TrackingSpeedController.maximum)
        swipeEnabled = defaults.bool(forKey: Keys.swipeEnabled)
        swipeLeftAction = defaults.string(forKey: Keys.swipeLeftAction).flatMap(SwipeGestureController.Action.init) ?? .moveRightSpace
        swipeRightAction = defaults.string(forKey: Keys.swipeRightAction).flatMap(SwipeGestureController.Action.init) ?? .moveLeftSpace
        mouseButtonsEnabled = defaults.bool(forKey: Keys.mouseButtonsEnabled)
        // Side button 1 moves left; holding the right button with either side button moves right.
        let savedActions = defaults.dictionary(forKey: Keys.mouseButtonActions) as? [String: String]
        mouseButtonActions = Dictionary(uniqueKeysWithValues: MouseButtonController.Trigger.allCases.map { trigger in
            let fallback: MouseAction = trigger == .side1 ? .moveLeftSpace : trigger == .side2 ? .none : .moveRightSpace
            return (trigger, savedActions?[trigger.rawValue].flatMap(MouseAction.init) ?? fallback)
        })
        buttonMappings = defaults.data(forKey: Keys.buttonMappings).flatMap { try? JSONDecoder().decode([ButtonMapping].self, from: $0) } ?? []
        keyRemapEnabled = defaults.bool(forKey: Keys.keyRemapEnabled)
        keyRemaps = defaults.data(forKey: Keys.keyRemaps).flatMap { try? JSONDecoder().decode([KeyRemap].self, from: $0) } ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
        micEngine.targetGain = Self.linear(gainDB)
        speakerEngine.targetGain = Self.linear(speakerGainDB)
        micEngine.onFormatChange = { [weak self] in MainActor.assumeIsolated { self?.applyState() } }
        speakerEngine.onFormatChange = { [weak self] in MainActor.assumeIsolated { self?.applySpeakerState() } }

        // Opening at login is on by default; after the first launch the user's choice sticks.
        if !defaults.bool(forKey: Keys.loginItemConfigured) {
            defaults.set(true, forKey: Keys.loginItemConfigured)
            launchAtLogin = true
            updateLoginItem()
        }

        refreshDevices()
        listenForDeviceChanges()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
        applyState()
        applySpeakerState()
        siteContent.refresh()
        contentWatch = siteContent.$content.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.evaluateLock() }
        }
        accountWatch = account.$user.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.evaluateLock() }
        }
        account.onSignedIn = { [weak self] in self?.syncPreferences(loadFirst: true) }
        // No key yet: signing in also makes one in the user's own account.
        account.wantsKeySetup = { [weak self] in !(self?.voiceTyping.hasKey ?? true) }
        account.onGoogleToken = { [weak self] token in self?.account.keySetup.received(token: token) }
        account.keySetup.signIn = { [weak self] in self?.account.signIn(setUpKey: true) }
        account.keySetup.save = { [weak self] key in await self?.voiceTyping.saveKeyChecked(key) ?? "MicFlow closed" }
        account.keySetup.afterSave = { [weak self] in self?.syncPreferences(loadFirst: false) }
        account.keySetup.fallbackEmail = { [weak self] in self?.account.user?.email }
        account.keySetup.hasKey = { [weak self] in self?.voiceTyping.hasKey ?? false }
        prefsWatch = voiceTyping.objectWillChange
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreferences(loadFirst: false) }
        evaluateLock()
        // New posts, update notes and pop-ups reach the app within half an hour.
        contentTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.siteContent.refresh() }
        }
        updater.autoInstallAllowed = { [weak self] in
            guard let self else { return false }
            return (self.siteContent.content.update?.autoUpdate ?? false) && self.voiceTyping.phase == .idle && !self.capture.isRecording
        }
        updater.start()

        middleClick.zoneWidth = Float(middleZoneWidth)
        middleClick.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.middleClickState = state } }
        if middleClickEnabled { middleClick.start() }

        figmaZoom.zoomAmount = figmaZoomAmount
        figmaZoom.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.figmaZoomState = state } }
        if figmaZoomEnabled { figmaZoom.start() }

        scrolling.smoothness = scrollSmoothness
        scrolling.shouldSkip = { [figmaZoom] in figmaZoom.isZoomingFrontmostApp }
        scrolling.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.scrollState = state } }
        applyScrolling()

        tracking.speed = trackingSpeed
        tracking.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.trackingState = state } }
        if trackingSpeedEnabled { tracking.start() }

        // Voice typing records the Sound tab's microphone itself and makes it louder by the Boost
        // amount, whether or not the boost for all apps is on, so meetings keep the normal mic.
        voiceTyping.inputDevice = { [weak self] in self?.selectedMic }
        voiceTyping.inputGain = { [weak self] in Self.linear(self?.gainDB ?? 0) }

        swipes.leftAction = swipeLeftAction
        swipes.rightAction = swipeRightAction
        swipes.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.swipeState = state } }
        if swipeEnabled { swipes.start() }

        mouseButtons.actions = mouseButtonActions
        mouseButtons.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.mouseButtonsState = state } }
        if mouseButtonsEnabled { mouseButtons.start() }

        keyRemapper.remaps = keyRemaps
        keyRemapper.onStateChange = { [weak self] state in MainActor.assumeIsolated { self?.keyRemapState = state } }
        if keyRemapEnabled { keyRemapper.start() }
    }

    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    /// Scroll distance and smooth scrolling share one event tap, which runs while either is on.
    private func applyScrolling() {
        scrolling.distance = scrollDistanceEnabled ? scrollDistance : 1
        scrolling.smoothEnabled = smoothScrollEnabled
        scrollDistanceEnabled || smoothScrollEnabled ? scrolling.start() : scrolling.stop()
    }

    func openMicPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openKeyboardShortcutSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    func quit() {
        shutDown()
        // A recording in progress is finished and saved first.
        guard capture.isRecording else { return NSApp.terminate(nil) }
        capture.stopRecording { NSApp.terminate(nil) }
    }

    /// Stops both boosts and hands the Mac's sound back to the real speakers, so nothing is left
    /// playing into BlackHole 16ch after the app is gone.
    private func shutDown() {
        micEngine.stop()
        speakerEngine.stop()
        restoreSystemOutput()
        tracking.stop()
        mouseButtons.stop()
        keyRemapper.stop()
        voiceTyping.shutDown()
        capture.shutDown()
    }

    // MARK: Mic boost

    private func applyState() {
        needsMicPermission = false
        guard enabled, !locked else {
            stopEngine()
            setStatus("Boost is off.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            stopEngine()
            setStatus("Waiting for microphone permission…")
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor [weak self] in self?.applyState() }
            }
            return
        default:
            stopEngine()
            needsMicPermission = true
            setStatus("MicFlow needs microphone access. Allow it in Privacy & Security → Microphone.", error: true)
            return
        }
        guard let output = micVirtual else {
            stopEngine()
            setStatus("BlackHole 2ch isn't installed. Run \"1 Install BlackHole 2ch\" from the MicFlow disk image, then restart your Mac.", error: true)
            return
        }
        guard let mic = selectedMic else {
            stopEngine()
            setStatus("No microphone found.", error: true)
            return
        }
        do {
            if maxHardwareVolume { CA.setInputVolumeToMax(mic.id) }
            try micEngine.start(source: mic, destination: output, clock: mic)
            isRunning = true
            setStatus("Boosting \(mic.name).")
        } catch {
            isRunning = false
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func stopEngine() {
        micEngine.stop()
        isRunning = false
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    // MARK: Speaker boost

    private func applySpeakerState() {
        guard speakerEnabled, !locked else {
            stopSpeaker()
            setSpeakerStatus("Speaker boost is off.")
            return
        }
        guard let virtual = speakerVirtual else {
            stopSpeaker()
            setSpeakerStatus("BlackHole 16ch isn't installed. Run \"2 Install BlackHole 16ch\" from the MicFlow disk image, then restart your Mac.", error: true)
            return
        }
        guard let speaker = selectedSpeaker else {
            stopSpeaker()
            setSpeakerStatus("No speakers or earphones found.", error: true)
            return
        }
        // Remember the real speakers before the default output becomes BlackHole 16ch, since the
        // fallback in `selectedSpeaker` reads the default output. Saving re-enters this method.
        if selectedSpeakerUID != speaker.uid {
            selectedSpeakerUID = speaker.uid
            return
        }
        do {
            try speakerEngine.start(source: virtual, destination: speaker, clock: speaker)
            CA.setDefaultOutputDevice(virtual.id)
            speakerRunning = true
            setSpeakerStatus("Boosting your Mac's sound on \(speaker.name).")
        } catch {
            stopSpeaker()
            setSpeakerStatus(error.localizedDescription, error: true)
        }
    }

    private func stopSpeaker() {
        speakerEngine.stop()
        speakerRunning = false
        restoreSystemOutput()
    }

    /// If the Mac is still playing into BlackHole 16ch, point it back at the real speakers.
    private func restoreSystemOutput() {
        guard let virtual = speakerVirtual, CA.defaultOutputDevice() == virtual.id,
              let speaker = selectedSpeaker else { return }
        CA.setDefaultOutputDevice(speaker.id)
    }

    private func setSpeakerStatus(_ text: String, error: Bool = false) {
        speakerStatus = text
        speakerStatusIsError = error
    }

    /// While speaker boost is on, picking another output in Sound settings or Control Center
    /// (or macOS switching to newly connected earphones) means "boost this one instead".
    private func defaultOutputChanged() {
        guard speakerEnabled, let id = CA.defaultOutputDevice(), id != speakerVirtual?.id,
              let device = speakerDevices.first(where: { $0.id == id }) else { return }
        if selectedSpeakerUID != device.uid {
            selectedSpeakerUID = device.uid
        } else {
            applySpeakerState()
        }
    }

    // MARK: Devices

    private func refreshDevices() {
        let all = CA.devices()
        let virtuals = all.filter { $0.isBlackHole && $0.outputChannels > 0 && $0.inputChannels > 0 }
        micVirtual = virtuals.first { $0.name.contains("2ch") }
        speakerVirtual = virtuals.first { $0.name.contains("16ch") }
        micDevices = all.filter { $0.inputChannels > 0 && !$0.isBlackHole }
        speakerDevices = all.filter { $0.outputChannels > 0 && !$0.isBlackHole }
    }

    private func listenForDeviceChanges() {
        var devicesAddr = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CA.system, &devicesAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        var outputAddr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &outputAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
    }

    /// Restarts a boost only when one of its devices actually came or went.
    private func devicesChanged() {
        let oldMic = selectedMic, oldMicVirtual = micVirtual
        let oldSpeaker = selectedSpeaker, oldSpeakerVirtual = speakerVirtual
        refreshDevices()
        if selectedMic != oldMic || micVirtual != oldMicVirtual { applyState() }
        if selectedSpeaker != oldSpeaker || speakerVirtual != oldSpeakerVirtual {
            applySpeakerState()
        } else {
            // A newly connected device may have become the default output before it was listed.
            defaultOutputChanged()
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            setStatus("Couldn't change the login setting: \(error.localizedDescription)", error: true)
        }
    }
}
