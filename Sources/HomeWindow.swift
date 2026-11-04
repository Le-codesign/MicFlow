import AppKit
import SwiftUI

/// The voice typing home, laid out like the planner dashboard in Design/Style Guide.md: a dark (or
/// forest green) frame with an icon sidebar, holding dark cards (activity, languages, weekly words,
/// numbers), one yellow card for today, and a big white panel with the dictations themselves.
@MainActor
enum HomeWindow {
    private static var window: NSWindow?

    static func show(model: BoostModel) {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1340, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "MicFlow"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = CGSize(width: 1180, height: 740)
            window.contentView = NSHostingView(rootView: HomeView(model: model, voice: model.voiceTyping, log: model.voiceTyping.log))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Style

/// Colors from the style guide.
enum Palette {
    static let pink = Color(hex: 0xF66399)
    static let yellow = Color(hex: 0xFFB413)
    static let orange = Color(hex: 0xF2621F)
    static let orangeLight = Color(hex: 0xFF8A3D)
    static let lavender = Color(hex: 0xB99AF6)
    static let cream = Color(hex: 0xFBEBC9)
    static let mint = Color(hex: 0xDDF3E2)
    static let mintText = Color(hex: 0x2E9E57)
    static let ink = Color(hex: 0x141414)
    static let white = Color.white
    static let greyOnDark = Color(hex: 0x9A9A9A)
    static let greyOnLight = Color(hex: 0x8A8A8A)
}

/// The two frames the sun/moon switch swaps between.
struct HomeTheme {
    let frame: Color
    let card: Color
    let selected: Color
    let bar: Color
    let barTop: Color

    static let dark = HomeTheme(frame: Color(hex: 0x141414), card: Color(hex: 0x232323), selected: Color(hex: 0x2E2E2E),
                                bar: Color(hex: 0x2C2C2C), barTop: Color(hex: 0x3A3A3A))
    static let green = HomeTheme(frame: Color(hex: 0x2B5036), card: Color(hex: 0x335E41), selected: Color(hex: 0x3B6A4A),
                                 bar: Color(hex: 0x2B5036), barTop: Color(hex: 0x44735A))
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The chunky, slightly condensed display type.
extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}

struct DarkCard<Content: View>: View {
    let theme: HomeTheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            .foregroundStyle(Palette.white)
    }
}

/// Icon in a cream circle, title, grey subtitle, and an action icon on the right.
struct CardHeader: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var action: String?
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.cream).frame(width: 32, height: 32)
                .overlay(Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.pink))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.greyOnDark) }
            }
            Spacer()
            if let action {
                Button(action: onAction) { Image(systemName: action).font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Fully round pill: filled when selected, outlined otherwise.
struct Pill: View {
    let title: String
    let selected: Bool
    var onDark = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(selected ? (onDark ? Palette.ink : Palette.white) : (onDark ? Palette.white : Palette.ink))
                .background(selected ? (onDark ? Palette.cream : Palette.ink) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(onDark && !selected ? Color.white.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window content

private struct HomeView: View {
    @ObservedObject var model: BoostModel
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var log: DictationLog
    /// Green is the default; the switch turns on the dark frame.
    @AppStorage("homeDarkTheme") private var dark = false
    @AppStorage("homePage") private var page = Page.home

    /// Home and Dictionary, then every tab of the menu bar panel, then General.
    enum Page: String, CaseIterable {
        case home, dictionary, sound, voice, mouse, keyboard, figma, capture, general

        var title: String {
            switch self {
            case .home: return "Home"
            case .dictionary: return "Preferences"
            case .sound: return "Sound"
            case .voice: return "Voice Typing"
            case .mouse: return "Mouse"
            case .keyboard: return "Keyboard"
            case .figma: return "Figma"
            case .capture: return "Capture"
            case .general: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .dictionary: return "slider.horizontal.3"
            case .sound: return "speaker.wave.2.fill"
            case .voice: return "waveform"
            case .mouse: return "computermouse.fill"
            case .keyboard: return "keyboard.fill"
            case .figma: return "plus.magnifyingglass"
            case .capture: return "camera.viewfinder"
            case .general: return "gearshape.fill"
            }
        }

        /// The name under the sidebar icon.
        var shortTitle: String { self == .voice ? "Voice" : self == .dictionary ? "Prefs" : title }
    }

    var theme: HomeTheme { dark ? .dark : .green }

    var body: some View {
        HStack(spacing: 10) {
            Sidebar(page: $page, dark: $dark, theme: theme)
            VStack(spacing: 10) {
                // Until voice typing has a key, every page but Home points back to Home's setup.
                if page != .home { VoiceSetupBanner(voice: voice, openHome: { page = .home }) }
                switch page {
                case .home:
                    VStack(spacing: 10) {
                        SetupBanner(voice: voice, openVoice: { page = .voice })
                        UpdateBanner(updater: model.updater, store: model.siteContent)
                        if voice.needsKeySetup {
                            HomeKeySetup(voice: voice, account: model.account, theme: theme)
                        } else {
                            HomeBoard(voice: voice, log: log, theme: theme, openDictionary: { page = .dictionary })
                        }
                    }
                case .dictionary: DictionaryPage(voice: voice, theme: theme)
                case .sound: SoundPage(model: model, theme: theme)
                case .voice: VoicePage(voice: voice, theme: theme, openDictionary: { page = .dictionary }, account: model.account)
                case .mouse: MousePage(model: model, theme: theme)
                case .keyboard: KeyboardPage(model: model, theme: theme)
                case .figma: FigmaPage(model: model, theme: theme)
                case .capture: CapturePage(capture: model.capture, imageHost: model.capture.imageHost, theme: theme)
                case .general: SettingsPage(model: model, theme: theme)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 10)
        }
        .background(theme.frame)
        .background(KeyGuideHost(flow: model.account.keySetup))
        .overlay {
            if model.locked, let blocker = model.siteContent.content.block {
                BlockerView(blocker: blocker, updater: model.updater, signIn: model.signInAction)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: dark)
    }
}

private struct Sidebar: View {
    @Binding var page: HomeView.Page
    @Binding var dark: Bool
    let theme: HomeTheme
    /// Wide: icons with their names beside them. Narrow: names under the icons.
    @AppStorage("sidebarExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: expanded ? .leading : .center, spacing: expanded ? 4 : 6) {
            header.padding(.top, expanded ? 46 : 38).padding(.bottom, expanded ? 14 : 8)
            item(.home)
            // Voice typing is the main feature, so it comes right after Home.
            item(.voice)
            Capsule().fill(Color.white.opacity(0.15)).frame(width: expanded ? nil : 28, height: 2)
                .padding(.vertical, 6).padding(.horizontal, expanded ? 8 : 0)
            ForEach([HomeView.Page.sound, .mouse, .keyboard, .figma, .capture, .dictionary], id: \.self) { item($0) }
            Spacer(minLength: 8)
            item(.general)
            Group {
                if expanded {
                    HStack(spacing: 8) { ThemeSwitch(dark: $dark); Spacer(); collapseButton }
                } else {
                    VStack(spacing: 8) { collapseButton; ThemeSwitch(dark: $dark) }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 18)
            .padding(.horizontal, expanded ? 8 : 0)
        }
        .padding(.horizontal, expanded ? 12 : 0)
        .frame(width: expanded ? 204 : 84, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    @ViewBuilder private var header: some View {
        if expanded {
            HStack(spacing: 10) {
                LogoMark(size: 38)
                Text("MicFlow").font(.display(22)).foregroundStyle(Palette.cream)
            }
            .padding(.leading, 6)
        } else {
            VStack(spacing: 2) {
                LogoMark(size: 42)
                Text("MicFlow").font(.display(15)).foregroundStyle(Palette.cream)
            }
        }
    }

    private var collapseButton: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: expanded ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Shrink the sidebar" : "Widen the sidebar")
        .accessibilityLabel(expanded ? "Shrink the sidebar" : "Widen the sidebar")
    }

    @ViewBuilder private func item(_ target: HomeView.Page) -> some View {
        if expanded { row(target) } else { tile(target) }
    }

    /// Wide: the icon, its name beside it, and a cream pill behind the current page.
    private func row(_ target: HomeView.Page) -> some View {
        let selected = page == target
        return Button { page = target } label: {
            HStack(spacing: 10) {
                Image(systemName: target.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Palette.pink : Palette.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(selected ? Palette.white : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(target.title)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Palette.ink : Palette.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(selected ? Palette.cream : .clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(target.title)
    }

    /// Narrow: a rounded tile with a filled icon and the page's name under it. The current page's
    /// tile is cream with a pink icon, like the icons on the cards.
    private func tile(_ target: HomeView.Page) -> some View {
        let selected = page == target
        return Button { page = target } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Palette.cream : Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0 : 0.10)))
                    .overlay(Image(systemName: target.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Palette.pink : Color.white.opacity(0.85)))
                    .frame(width: 38, height: 38)
                Text(target.shortTitle)
                    .font(.system(size: 9.5, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Palette.white : Palette.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(target.title)
    }
}

/// The app icon's flame character (Design/AppIcon.svg) drawn at any size: the forest tile, the
/// cream-to-sage flame and the two eyes.
struct LogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3A6B4A), Color(hex: 0x22452E)], startPoint: .top, endPoint: .bottom)
            FlameShape().fill(LinearGradient(stops: [.init(color: Color(hex: 0xFFF6DC), location: 0),
                                                     .init(color: Color(hex: 0xF1E6BE), location: 0.5),
                                                     .init(color: Color(hex: 0xA9D6A4), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
            EyesShape().fill(Color(hex: 0x1F4029))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2266, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2266, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The flame, from the icon's 1024-point artwork.
private struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(-10, 1034))
        path.addLine(to: p(-10, 730))
        path.addCurve(to: p(200, 314), control1: p(20, 560), control2: p(120, 400))
        path.addCurve(to: p(276, 590), control1: p(232, 288), control2: p(250, 380))
        path.addCurve(to: p(545, 128), control1: p(292, 400), control2: p(370, 140))
        path.addCurve(to: p(736, 490), control1: p(650, 124), control2: p(715, 170))
        path.addCurve(to: p(806, 292), control1: p(748, 370), control2: p(772, 292))
        path.addCurve(to: p(1034, 610), control1: p(860, 296), control2: p(920, 430))
        path.addLine(to: p(1034, 1034))
        path.closeSubpath()
        return path
    }
}

private struct EyesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 1024
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + (400 - 59) * s, y: rect.minY + (796 - 112) * s, width: 118 * s, height: 224 * s))
        path.addEllipse(in: CGRect(x: rect.minX + (592 - 59) * s, y: rect.minY + (800 - 112) * s, width: 118 * s, height: 224 * s))
        return path
    }
}

/// The switch at the bottom of the sidebar: forest green frame (the default) or dark frame.
private struct ThemeSwitch: View {
    @Binding var dark: Bool

    var body: some View {
        Button { dark.toggle() } label: {
            ZStack(alignment: dark ? .trailing : .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 52, height: 28)
                Circle().fill(Palette.white).frame(width: 24, height: 24).padding(2)
                    .overlay(Image(systemName: dark ? "moon.fill" : "leaf.fill").font(.system(size: 11))
                        .foregroundStyle(dark ? Palette.ink : Color(hex: 0x2B5036)))
            }
        }
        .buttonStyle(.plain)
        .help(dark ? "Green theme" : "Dark theme")
    }
}

// MARK: - Home board

private struct HomeBoard: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var log: DictationLog
    let theme: HomeTheme
    let openDictionary: () -> Void
    @State private var listMode = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                ActivityCard(log: log, theme: theme)
                TodayCard(log: log, showHistory: { listMode = true })
                LanguagesCard(log: log, theme: theme, openDictionary: openDictionary)
            }
            .frame(width: 318)
            VStack(spacing: 10) {
                DictationsPanel(log: log, listMode: $listMode, openDictionary: openDictionary)
                HStack(spacing: 10) {
                    WeeklyCard(log: log, theme: theme)
                    NumbersCard(log: log, theme: theme)
                        .frame(width: 330)
                }
                .frame(height: 262)
            }
        }
    }
}

/// The month as day circles; days with dictations are pink, today has a ring.
private struct ActivityCard: View {
    @ObservedObject var log: DictationLog
    let theme: HomeTheme
    @State private var monthOffset = 0

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var month: Date {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        return calendar.date(byAdding: .month, value: monthOffset, to: start)!
    }

    private struct Cell: Identifiable {
        enum Kind { case weekday(String), blank, day(Int) }
        let id: String
        let kind: Kind
    }

    private func cells(lead: Int, days: Int) -> [Cell] {
        ["M", "T", "W", "T", "F", "S", "S"].enumerated().map { Cell(id: "w\($0.offset)", kind: .weekday($0.element)) }
            + (0..<lead).map { Cell(id: "b\($0)", kind: .blank) }
            + (1...days).map { Cell(id: "d\($0)", kind: .day($0)) }
    }

    var body: some View {
        let dictated = Set(log.entries.map { calendar.startOfDay(for: $0.date) })
        let days = calendar.range(of: .day, in: .month, for: month)!.count
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let today = calendar.startOfDay(for: Date())
        let columns = Array(repeating: GridItem(.fixed(34), spacing: 5), count: 7)

        DarkCard(theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(systemImage: "bolt.fill", title: "Activity", subtitle: "Days you dictated")
                HStack(spacing: 6) {
                    Pill(title: "This month", selected: monthOffset == 0) { monthOffset = 0 }
                    Pill(title: "Last month", selected: monthOffset == -1) { monthOffset = -1 }
                    Spacer()
                }
                LazyVGrid(columns: columns, spacing: 5) {
                    // One list of cells with unique IDs: separate ForEach loops counting from 0
                    // and 1 share IDs, and the grid then drops cells.
                    ForEach(cells(lead: lead, days: days)) { cell in
                        switch cell.kind {
                        case .weekday(let letter):
                            Text(letter).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.greyOnDark)
                        case .blank:
                            Circle().strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: 32, height: 32)
                        case .day(let number):
                            let day = calendar.date(byAdding: .day, value: number - 1, to: month)!
                            let active = dictated.contains(day)
                            Text("\(number)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(active ? Palette.white : Palette.ink.opacity(day > today ? 0.4 : 1))
                                .frame(width: 32, height: 32)
                                .background(active ? Palette.pink : Palette.cream, in: Circle())
                                .overlay(Circle().strokeBorder(day == today ? Palette.white : .clear, lineWidth: 2).padding(-3))
                        }
                    }
                }
                HStack {
                    Button { monthOffset -= 1 } label: { Image(systemName: "arrow.left") }.buttonStyle(.plain)
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { monthOffset = min(0, monthOffset + 1) } label: { Image(systemName: "arrow.right") }
                        .buttonStyle(.plain).opacity(monthOffset < 0 ? 1 : 0.3)
                }
                .font(.system(size: 15, weight: .medium))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one yellow card: today's words, with a sticker.
private struct TodayCard: View {
    @ObservedObject var log: DictationLog
    let showHistory: () -> Void
    @State private var copied = false

    var body: some View {
        let words = log.words(on: Date())
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today · \(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Palette.pink).frame(width: 7, height: 7)
                    Text("\(log.averageWPM) WPM").font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Palette.white, in: Capsule())
            }
            Text(words == 0 ? "Hold your key and\nstart talking" : "\(words.formatted()) words\ndictated today")
                .font(.display(25))
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button {
                    guard let last = log.entries.last else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Text(copied ? "Copied" : "Copy last")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Palette.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(log.entries.isEmpty)
                Button("History", action: showHistory).buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(18)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .bottomTrailing) { Sticker().offset(x: 6, y: 10) }
    }
}

/// A tilted pink sticker with a white edge, breaking out of the card's corner.
private struct Sticker: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.pink)
            .frame(width: 70, height: 62)
            .overlay(Image(systemName: "mic.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.cream))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.white, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "waveform").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
                    .padding(5).background(Palette.yellow, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 1.5))
                    .offset(x: 8, y: -8)
            }
            .rotationEffect(.degrees(-10))
    }
}

/// English and Bengali, like the reference's checklist with pink badges.
private struct LanguagesCard: View {
    @ObservedObject var log: DictationLog
    let theme: HomeTheme
    let openDictionary: () -> Void

    var body: some View {
        let share = log.bengaliShare
        let any = log.totalWords > 0
        DarkCard(theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Languages").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                row("English", used: any && share < 1, percent: any ? 1 - share : 0)
                row("বাংলা Bengali", used: share > 0, percent: share)
                Spacer(minLength: 0)
                Button(action: openDictionary) {
                    Label("Add a word", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ title: String, used: Bool, percent: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: used ? "checkmark.square.fill" : "square").font(.system(size: 14))
                .foregroundStyle(used ? Palette.white : Palette.greyOnDark)
            Text(title).font(.system(size: 13))
            Text(percent.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Palette.pink, in: Capsule())
            Spacer()
        }
    }
}

// MARK: - Dictations panel

/// The big white panel: the last four days as columns, each dictation a colored card, like the
/// reference's schedule. List shows them as plain rows instead.
private struct DictationsPanel: View {
    @ObservedObject var log: DictationLog
    @Binding var listMode: Bool
    let openDictionary: () -> Void
    @State private var search = ""

    private var matches: [DictationLog.Entry] {
        let all = log.entries.reversed()
        return search.isEmpty ? Array(all) : all.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(Date().formatted(.dateTime.month(.wide))) + Text(", \(Date().formatted(.dateTime.year()))")
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                }
                .font(.display(30))
                Spacer()
                HStack(spacing: 2) {
                    Pill(title: "Cards", selected: !listMode, onDark: false) { listMode = false }
                    Pill(title: "List", selected: listMode, onDark: false) { listMode = true }
                }
                .padding(3)
                .background(Color(hex: 0xF2F2F0), in: Capsule())
                Button(action: openDictionary) {
                    Label("Add word", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Palette.yellow, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.greyOnLight)
                TextField("Search your dictations…", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(hex: 0xF2F2F0), in: Capsule())
            .frame(maxWidth: 360)

            if listMode || !search.isEmpty {
                ListView(entries: matches)
            } else {
                DayColumns(log: log)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

private struct DayColumns: View {
    @ObservedObject var log: DictationLog

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<4).map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        HStack(alignment: .top, spacing: 0) {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                let entries = log.entries.filter { calendar.isDate($0.date, inSameDayAs: day) }.reversed()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(calendar.component(.day, from: day))").font(.display(22))
                        Text("/\(day.formatted(.dateTime.weekday(.abbreviated)))").font(.system(size: 12))
                            .foregroundStyle(Palette.greyOnLight)
                        if index == 0 {
                            Text("Today").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Palette.pink, in: Capsule())
                                .padding(.leading, 6)
                        }
                    }
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if entries.isEmpty {
                                EmptySlot(today: index == 0)
                            } else {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                                    DictationCard(entry: entry, style: DictationCard.Style.allCases[(offset + index) % 5])
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) {
                    if index > 0 { DashedLine(vertical: true).frame(width: 1) }
                }
            }
        }
        .background(alignment: .top) {
            // The dashed guide lines across the panel.
            VStack(spacing: 70) { ForEach(0..<6, id: \.self) { _ in DashedLine(vertical: false).frame(height: 1) } }
                .padding(.top, 44)
        }
    }
}

private struct DashedLine: View {
    let vertical: Bool

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: vertical ? CGPoint(x: 0, y: geo.size.height) : CGPoint(x: geo.size.width, y: 0))
            }
            .stroke(Color.black.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

/// The mint dashed slot, like "Add new task".
private struct EmptySlot: View {
    let today: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.badge.plus").font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30).background(Color.white.opacity(0.7), in: Circle())
            Text(today ? "Hold your key\nto dictate" : "No dictations").font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.mintText)
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .background(Palette.mint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Palette.mintText.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

/// One dictation as a colored card; click to copy it again.
private struct DictationCard: View {
    enum Style: CaseIterable { case orange, lavender, pink, yellow, cream }

    let entry: DictationLog.Entry
    let style: Style
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if style == .orange || style == .pink {
                    Texture(base: style == .orange ? Palette.orange : Palette.pink,
                            light: style == .orange ? Palette.orangeLight : Color(hex: 0xFFB3CF))
                        .frame(height: 46)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(copied ? "Copied" : "\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.words) words")
                        .font(.system(size: 10, weight: .semibold)).opacity(0.75)
                    Text(entry.text).font(.system(size: 13, weight: .bold)).lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private var background: Color {
        switch style {
        case .orange: return Palette.orange
        case .lavender: return Palette.lavender
        case .pink: return Palette.pink
        case .yellow: return Palette.yellow
        case .cream: return Palette.cream
        }
    }

    private var foreground: Color {
        style == .yellow || style == .cream ? Palette.ink : Palette.white
    }
}

/// Flowing bands like the reference's marbled image cards, drawn rather than photographed.
private struct Texture: View {
    let base: Color
    let light: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            for band in 0..<7 {
                var path = Path()
                let y0 = size.height * (CGFloat(band) / 6) - 6
                path.move(to: CGPoint(x: 0, y: y0))
                for step in 0...24 {
                    let x = size.width * CGFloat(step) / 24
                    path.addLine(to: CGPoint(x: x, y: y0 + sin(Double(step) / 3.5 + Double(band)) * 7))
                }
                context.stroke(path, with: .color(light.opacity(band % 2 == 0 ? 0.85 : 0.45)), lineWidth: 4)
            }
        }
    }
}

private struct ListView: View {
    let entries: [DictationLog.Entry]

    var body: some View {
        if entries.isEmpty {
            Text("No dictations match.").font(.system(size: 13)).foregroundStyle(Palette.greyOnLight).padding(.top, 20)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(entries.prefix(200)) { entry in ListRow(entry: entry) }
                }
            }
        }
    }
}

private struct ListRow: View {
    let entry: DictationLog.Entry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.greyOnLight)
                .frame(width: 110, alignment: .leading)
            Text(entry.text).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(entry.words) words").font(.system(size: 11)).foregroundStyle(Palette.greyOnLight)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)) }
                .buttonStyle(.plain)
                .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(hovering ? Color(hex: 0xF2F2F0) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}

// MARK: - Bottom cards

/// Words per day this week: grey bars, today in yellow over orange stripes, with a tooltip.
private struct WeeklyCard: View {
    @ObservedObject var log: DictationLog
    let theme: HomeTheme

    var body: some View {
        let days = log.lastSevenDays
        let most = max(days.map(\.words).max() ?? 0, 10)
        let todayCount = log.entries.filter { Calendar.current.isDateInToday($0.date) }.count
        DarkCard(theme: theme) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly Words Overview").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chart.bar").font(.system(size: 12))
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.2)))
                }
                (Text("Last 7 days ").foregroundColor(Palette.greyOnDark) + Text("\(days.map(\.words).reduce(0, +).formatted()) words"))
                    .font(.system(size: 11, weight: .medium))
                GeometryReader { geo in
                    let height = geo.size.height - 22
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading) {
                            ForEach([1.0, 0.66, 0.33], id: \.self) { fraction in
                                Text("\(Int(Double(most) * fraction))").font(.system(size: 9)).foregroundStyle(Palette.greyOnDark)
                                Spacer()
                            }
                        }
                        .frame(height: height)
                        .padding(.bottom, 22)
                        ForEach(days.indices, id: \.self) { index in
                            let isToday = index == days.count - 1
                            let barHeight = max(8, height * CGFloat(days[index].words) / CGFloat(most))
                            VStack(spacing: 6) {
                                ZStack(alignment: .top) {
                                    if isToday {
                                        Stripes().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.yellow)
                                            .frame(height: min(barHeight, 16))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.bar)
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.barTop)
                                            .frame(height: barHeight * 0.45)
                                    }
                                }
                                .frame(height: barHeight)
                                Text(days[index].day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 10, weight: isToday ? .bold : .regular))
                                    .foregroundStyle(isToday ? Palette.white : Palette.greyOnDark)
                                    .frame(height: 16)
                            }
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .top) {
                                if isToday {
                                    Tooltip(words: days[index].words, dictations: todayCount)
                                        .fixedSize()
                                        .offset(x: -64, y: max(-6, height - barHeight - 64))
                                }
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

private struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.orange))
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(Palette.orangeLight), lineWidth: 3)
                x += 8
            }
        }
    }
}

private struct Tooltip: View {
    let words: Int
    let dictations: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Today").font(.system(size: 9)).foregroundStyle(Palette.greyOnDark)
            legend(Palette.yellow, "Words", words)
            legend(Palette.orange, "Dictations", dictations)
        }
        .padding(9)
        .background(Color(hex: 0x3A3A3A), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func legend(_ color: Color, _ title: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 10))
            Spacer(minLength: 12)
            Text(value.formatted()).font(.system(size: 10, weight: .bold))
        }
    }
}

/// The numbers, as list rows like the reference's "Archive Project".
private struct NumbersCard: View {
    @ObservedObject var log: DictationLog
    let theme: HomeTheme

    var body: some View {
        DarkCard(theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your Numbers").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "ellipsis")
                }
                .padding(.bottom, 4)
                row("speedometer", Palette.pink, "Average speed", "\(log.averageWPM)", "WPM", highlighted: true)
                row("text.word.spacing", Palette.yellow, "Total words", log.totalWords.formatted(), "")
                row("flame.fill", Palette.orange, "Streak", "\(log.streak)", log.streak == 1 ? "day" : "days")
                row("hourglass", Palette.lavender, "Time saved", Self.duration(log.minutesSaved), "")
            }
        }
    }

    private func row(_ icon: String, _ color: Color, _ title: String, _ value: String, _ unit: String,
                     highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24).background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold))
            if !unit.isEmpty { Text(unit).font(.system(size: 11)).foregroundStyle(Palette.greyOnDark) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
