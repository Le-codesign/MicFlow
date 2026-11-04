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
    let model = BoostModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        HomeWindow.show(model: model)
        InstallLocation.offerMoveIfNeeded()
        #if ADMIN
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
                ForEach(Tab.allCases, id: \.self) { item in
                    let selected = item == tab
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
            .animation(.easeOut(duration: 0.15), value: tab)

            // Every tab gets the same fixed height and scrolls inside it: a menu bar panel that
            // changes height leaves a see-through gap where it used to be.
            Group {
                if model.locked, let blocker = model.siteContent.content.block {
                    BlockerView(blocker: blocker, updater: model.updater, signIn: model.signInAction)
                } else {
                switch tab {
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
