import SwiftUI

/// MicFlow is a normal app with a Dock icon, plus its menu bar icon: opening it (from Spotlight,
/// Launchpad or the Dock) shows the Home window.
@main
struct MicFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            BoostView(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: BoostModel

    override init() {
        // Before anything starts (shortcuts, key remaps, updates): only one MicFlow at a time.
        SingleInstance.ensure()
        model = BoostModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MicFlowNotifier.shared.setUp()
        model.clipboard.start()
        MicFlowNotifier.shared.update = { [model] in
            // One click: install the new version (checking first if it isn't known yet).
            if case .available = model.updater.state { model.updater.install() } else { model.updater.check() }
        }
        MicFlowNotifier.shared.openPosts = { [model] in
            UserDefaults.standard.set("general", forKey: "homePage")
            UserDefaults.standard.set("What's New", forKey: "settingsTab")
            HomeWindow.show(model: model)
        }
        HomeWindow.show(model: model)
        InstallLocation.cleanUpAfterUpdate()
        InstallLocation.offerMoveIfNeeded()
        #if ADMIN
        model.account.keySetup.previewIfAsked()
        CleanupSelfTest.runIfAsked()
        #endif
    }

    /// Clicking the Dock icon, or opening the app again, brings the Home window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HomeWindow.show(model: model)
        return false
    }

    /// Closing the window leaves MicFlow running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting from the MicFlow menu (⌘Q) while recording saves the video first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.capture.isRecording else { return .terminateNow }
        model.capture.stopRecording { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: BoostModel

    var body: some View {
        Image(systemName: model.isRunning ? "mic.badge.plus" : model.speakerRunning ? "speaker.wave.3" : "mic")
    }
}

/// The menu bar panel, in the same style as the Home window: the green (or dark) frame, round
/// icon tabs, and each tab's page in one column.
struct BoostView: View {
    @ObservedObject var model: BoostModel
    @ObservedObject var account: Account

    init(model: BoostModel) {
        self.model = model
        account = model.account
    }
    @AppStorage("homeDarkTheme") private var dark = false

    private enum Tab: String, CaseIterable {
        case sound = "Sound", voice = "Voice", mouse = "Mouse", keyboard = "Keyboard", figma = "Figma", capture = "Capture"

        var systemImage: String {
            switch self {
            case .sound: return "speaker.wave.2.fill"
            case .voice: return "waveform"
            case .mouse: return "computermouse.fill"
            case .keyboard: return "keyboard.fill"
            case .figma: return "plus.magnifyingglass"
            case .capture: return "camera.viewfinder"
            }
        }
    }

    /// Remembered across launches, so the panel reopens on the last tab used.
    @AppStorage("selectedTab") private var tab = Tab.sound

    private var theme: HomeTheme { dark ? .dark : .green }

    /// Voice is hidden while signed out: a remembered Voice tab shows Sound instead.
    private var shownTab: Tab { tab == .voice && !account.showsVoiceTab ? .sound : tab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogoMark(size: 26)
                Text("MicFlow").font(.display(19))
                Spacer()
                PillButton(title: "Home", systemImage: "house.fill", style: .cream) { HomeWindow.show(model: model) }
            }
            .foregroundStyle(Palette.white)

            // Round icon tabs: the selected one cream with its name.
            HStack(spacing: 6) {
                ForEach(Tab.allCases.filter { $0 != .voice || account.showsVoiceTab }, id: \.self) { item in
                    let selected = item == shownTab
                    Button { tab = item } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.systemImage).font(.system(size: 13, weight: .bold))
                            if selected { Text(item.rawValue).font(.system(size: 12, weight: .semibold)) }
                        }
                        .foregroundStyle(selected ? Palette.ink : Palette.white)
                        .frame(height: 34)
                        .padding(.horizontal, selected ? 14 : 0)
                        .frame(minWidth: 34)
                        .background(selected ? Palette.cream : Color.white.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(item.rawValue)
                }
            }
            .animation(.easeOut(duration: 0.15), value: shownTab)

            // Every tab gets the same fixed height and scrolls inside it: a menu bar panel that
            // changes height leaves a see-through gap where it used to be.
            Group {
                if model.locked, let blocker = model.siteContent.content.block {
                    BlockerView(blocker: blocker, updater: model.updater, signIn: model.signInAction)
                } else {
                switch shownTab {
                case .sound: SoundPage(model: model, theme: theme)
                case .voice:
                    VoicePage(voice: model.voiceTyping, theme: theme) {
                        UserDefaults.standard.set("dictionary", forKey: "homePage")
                        HomeWindow.show(model: model)
                    }
                case .mouse: MousePage(model: model, theme: theme)
                case .keyboard: KeyboardPage(model: model, theme: theme)
                case .figma: FigmaPage(model: model, theme: theme)
                case .capture: CapturePage(capture: model.capture, imageHost: model.capture.imageHost, theme: theme)
                }
                }
            }
            .environment(\.compactLayout, true)
            .frame(height: 500)

            HStack {
                CheckRow(title: "Open at login", isOn: $model.launchAtLogin)
                    .foregroundStyle(Palette.white)
                    .fixedSize()
                Spacer()
                PillButton(title: "Quit", systemImage: "power", style: .outline) { model.quit() }
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(theme.frame)
        .fixedSize()
    }
}

/// Two copies of MicFlow (say, one in Applications and one opened from the disk image, or one
/// opened at login and one opened by hand) would both answer every shortcut and type twice.
@MainActor
enum SingleInstance {
    static func ensure() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard !others.isEmpty else { return }
        let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        func version(_ app: NSRunningApplication) -> String {
            app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "0"
        }
        #if ADMIN
        // The admin edition is the one to keep on its own Mac.
        let replaceOthers = true
        #else
        // A newer copy (just downloaded) takes over from an older one; otherwise the one already running stays.
        let replaceOthers = others.allSatisfy { Updater.isNewer(mine, than: version($0)) }
        #endif
        if replaceOthers {
            others.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(4)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            return
        }
        // Brings the copy that's already running forward (its Home window opens) and quits.
        if let url = others.first?.bundleURL {
            let opened = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in opened.signal() }
            _ = opened.wait(timeout: .now() + 3)
        }
        exit(0)
    }
}
