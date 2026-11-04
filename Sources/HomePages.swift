import SwiftUI

// The Home window's settings pages, in the same language as the Home page (Design/Style Guide.md):
// one yellow hero card per page with a sticker, dark cards on the frame for each feature with a
// pink switch, cream sliders and pill menus, and a white panel where a page has a list.

// MARK: - Building blocks

/// True in the menu bar panel: cards stack in one column and the hero is smaller.
private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

/// The page's one yellow card: what the page is for and how it stands right now.
struct HeroCard<Actions: View>: View {
    let kicker: String
    let title: String
    var detail: String?
    var chip: String?
    let systemImage: String
    @ViewBuilder var actions: Actions
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            HStack {
                Text(kicker).font(.system(size: 11, weight: .semibold))
                Spacer()
                if let chip {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.pink).frame(width: 7, height: 7)
                        Text(chip).font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.white, in: Capsule())
                }
            }
            Text(title).font(.display(compact ? 21 : 28)).fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, compact ? 54 : 0)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: compact ? 12 : 13, weight: .medium)).opacity(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, compact ? 54 : 90)
            }
            HStack(spacing: 14) { actions }
        }
        .foregroundStyle(Palette.ink)
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            PageSticker(systemImage: systemImage).scaleEffect(compact ? 0.7 : 1)
                .padding(.trailing, compact ? 10 : 26).padding(.bottom, compact ? 8 : 14)
        }
    }
}

/// A tilted pink sticker with a white edge, like the Home page's.
struct PageSticker: View {
    let systemImage: String

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.pink)
            .frame(width: 70, height: 62)
            .overlay(Image(systemName: systemImage).font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.cream))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.white, lineWidth: 3))
            .rotationEffect(.degrees(-10))
    }
}

/// A dark card for one feature: icon, title, subtitle and a pink switch; its settings show while
/// it's on.
struct FeatureCard<Content: View>: View {
    let theme: HomeTheme
    let systemImage: String
    let title: String
    var subtitle: String?
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        DarkCard(theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Palette.cream).frame(width: 32, height: 32)
                        .overlay(Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.pink))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.greyOnDark) }
                    }
                    Spacer()
                    if let isOn { PinkSwitch(isOn: isOn) }
                }
                if isOn?.wrappedValue ?? true { content }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// On: pink track. Off: a faint track.
struct PinkSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.pink : Color.white.opacity(0.16)).frame(width: 44, height: 26)
                Circle().fill(Palette.white).frame(width: 20, height: 20).padding(3)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
    }
}

/// A label and value above a cream slider.
struct CreamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    var lowLabel: String?
    var highLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(valueText).font(.system(size: 13, weight: .bold)).monospacedDigit()
            }
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = geo.size.width * CGFloat(min(max(fraction, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: 6)
                    Capsule().fill(Palette.cream).frame(width: max(6, x), height: 6)
                    Circle().fill(Palette.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: x - 9)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = range.lowerBound + Double(drag.location.x / geo.size.width) * (range.upperBound - range.lowerBound)
                    let snapped = (raw / step).rounded() * step
                    value = min(max(snapped, range.lowerBound), range.upperBound)
                })
            }
            .frame(height: 18)
            if lowLabel != nil || highLabel != nil {
                HStack {
                    Text(lowLabel ?? "")
                    Spacer()
                    Text(highLabel ?? "")
                }
                .font(.system(size: 10)).foregroundStyle(Palette.greyOnDark)
            }
        }
    }
}

/// A slider for a multiplier from ¼× to 4×, with 1× in the middle.
struct MultiplierCreamSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        CreamSlider(title: title, value: Binding(get: { log2(value) }, set: { value = pow(2, $0) }), range: -2...2, step: 0.25,
                    valueText: String(format: "%.2g×", value), lowLabel: "Less", highLabel: "More")
    }
}

/// A pill showing the current choice; click it for the list of choices.
struct PillMenu<Value: Hashable>: View {
    var label: String?
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var onDark = true
    @State private var open = false
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack {
            if let label { Text(label).font(.system(size: 13)); Spacer() }
            Button { open = true } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.value == selection }?.title ?? "Choose").font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: label == nil ? .infinity : compact ? 170 : 230)
                .background(onDark ? Color.white.opacity(0.08) : Color(hex: 0xF2F2F0), in: Capsule())
                .overlay(Capsule().strokeBorder(onDark ? Color.white.opacity(0.14) : Color.black.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(options.indices, id: \.self) { index in
                            let option = options[index]
                            Button {
                                selection = option.value
                                open = false
                            } label: {
                                HStack {
                                    Text(option.title).font(.system(size: 13, weight: option.value == selection ? .semibold : .regular))
                                    Spacer()
                                    if option.value == selection { Image(systemName: "checkmark").foregroundStyle(Palette.pink) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(option.value == selection ? Palette.cream : .clear, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 260)
                .frame(maxHeight: 360)
                .foregroundStyle(Palette.ink)
                .environment(\.colorScheme, .light)
            }
        }
    }
}

/// A peak meter in the accent colors: cream, then yellow near full, pink when the limiter works.
struct CreamMeter: View {
    let engine: BoostEngine
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            let db = 20 * log10(max(Double(active ? engine.peakLevel : 0), 1e-5))
            let fraction = min(max((db + 60) / 60, 0), 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(db > -3 ? Palette.pink : db > -12 ? Palette.yellow : Palette.cream)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
    }
}

struct CheckRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Palette.pink : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? .clear : Color.white.opacity(0.35), lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white).opacity(isOn ? 1 : 0))
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 13)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Grey help text, or pink with a warning sign for a problem.
struct Note: View {
    let text: String
    var isError = false

    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isError { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.pink) }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(isError ? Palette.pink : Palette.greyOnDark)
        }
    }
}

enum PillButtonStyle { case cream, orange, yellow, outline, ink }

struct PillButton: View {
    let title: String
    var systemImage: String?
    var style = PillButtonStyle.cream
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(style == .outline ? Color.white.opacity(0.2) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .cream: return Palette.cream
        case .orange: return Palette.orange
        case .yellow: return Palette.yellow
        case .outline: return .clear
        case .ink: return Palette.ink
        }
    }

    private var foreground: Color {
        switch style {
        case .cream, .yellow: return Palette.ink
        case .orange, .ink, .outline: return Palette.white
        }
    }
}

/// "MicFlow needs Accessibility" in the card's style.
struct AccessibilityNotice: View {
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(text: "MicFlow needs Accessibility permission for this. Turn on MicFlow in Privacy & Security → Accessibility.", isError: true)
            PillButton(title: "Open Accessibility Settings", systemImage: "lock.open", action: open)
        }
    }
}

/// A text field on a dark card, or on the white panel.
struct PillField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onDark = true
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onSubmit(onSubmit)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(onDark ? Color.white.opacity(0.08) : Color(hex: 0xF2F2F0), in: Capsule())
        .overlay(Capsule().strokeBorder(onDark ? Color.white.opacity(0.12) : .clear))
    }
}

/// A page on the frame: the yellow hero, then the cards.
struct PageBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(.bottom, 4)
        }
    }
}

/// Two columns of cards, filled left then right.
struct CardColumns<Left: View, Right: View>: View {
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            VStack(spacing: 10) { left; right }
        } else {
            columns
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) { left }.frame(maxWidth: .infinity)
            VStack(spacing: 10) { right }.frame(maxWidth: .infinity)
        }
    }
}

/// The white panel, for lists.
struct WhitePanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .foregroundStyle(Palette.ink)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .light)
    }
}

// MARK: - Sound

struct SoundPage: View {
    @ObservedObject var model: BoostModel
    let theme: HomeTheme

    var body: some View {
        PageBody {
            HeroCard(kicker: "Sound", title: title, detail: detail,
                     chip: model.isRunning ? String(format: "+%.1f dB", model.gainDB) : nil, systemImage: "speaker.wave.3.fill") {
                PillButton(title: "Sound Settings…", style: .orange, action: model.openSoundSettings)
                if model.needsMicPermission {
                    PillButton(title: "Microphone Privacy…", style: .ink, action: model.openMicPrivacySettings)
                }
            }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "mic.fill", title: "Microphone", subtitle: "Boost it in all apps too",
                            isOn: $model.enabled) {
                    PillMenu(selection: Binding(get: { model.selectedMic?.uid ?? "" }, set: { model.selectedMicUID = $0 }),
                             options: model.micDevices.map { ($0.uid, $0.name) })
                    CreamSlider(title: "Boost", value: $model.gainDB, range: 0...BoostModel.maxGainDB, step: 0.5,
                                valueText: String(format: "+%.1f dB · %.1f×", model.gainDB, Double(BoostModel.linear(model.gainDB))))
                    CreamMeter(engine: model.micEngine, active: model.isRunning)
                    Note(text: model.status, isError: model.statusIsError)
                    CheckRow(title: "Set microphone hardware level to 100%", isOn: $model.maxHardwareVolume)
                    Note(text: "Voice typing always uses this microphone at this boost. Turn the switch on only if you also want it louder in other apps: they then pick BlackHole 2ch as the microphone. Leave it off for meetings to sound normal.")
                }
            } right: {
                FeatureCard(theme: theme, systemImage: "speaker.wave.2.fill", title: "Speakers", subtitle: "Make your Mac's sound louder",
                            isOn: $model.speakerEnabled) {
                    PillMenu(selection: Binding(get: { model.selectedSpeaker?.uid ?? "" }, set: { model.selectedSpeakerUID = $0 }),
                             options: model.speakerDevices.map { ($0.uid, $0.name) })
                    CreamSlider(title: "Boost", value: $model.speakerGainDB, range: 0...BoostModel.maxGainDB, step: 0.5,
                                valueText: String(format: "+%.1f dB · %.1f×", model.speakerGainDB, Double(BoostModel.linear(model.speakerGainDB))))
                    CreamMeter(engine: model.speakerEngine, active: model.speakerRunning)
                    Note(text: model.speakerStatus, isError: model.speakerStatusIsError)
                    Note(text: "Your volume keys still work as usual. With headphones, start low.")
                }
            }
        }
    }

    private var title: String {
        model.isRunning ? String(format: "Your voice is %.1f× louder", Double(BoostModel.linear(model.gainDB)))
            : String(format: "Voice typing hears you %.0f× louder", Double(BoostModel.linear(model.gainDB)))
    }

    private var detail: String {
        if model.isRunning, let output = model.micVirtual { return "In Zoom, Discord, Meet and others, choose \(output.name) as the microphone." }
        if !model.enabled { return "Other apps get your normal microphone." }
        return model.status
    }
}

// MARK: - Voice typing

struct VoicePage: View {
    @ObservedObject var voice: VoiceTypingModel
    let theme: HomeTheme
    let openDictionary: () -> Void
    /// For "Set it up for me": signs in with Google and makes the key.
    var account: Account? = nil
    @State private var keyDraft = ""

    var body: some View {
        PageBody {
            HeroCard(kicker: "Voice Typing", title: voice.enabled ? "Hold \(voice.hotkeyName) and talk" : "Voice typing is off",
                     detail: voice.enabled ? voice.status : "Turn it on below, then hold a key, speak, and let go.",
                     chip: voice.enabled ? voice.engine.shortTitle : nil, systemImage: "waveform") {
                if voice.needsAccessibility {
                    PillButton(title: "Open Accessibility Settings", style: .ink, action: voice.openAccessibilitySettings)
                }
            }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "waveform", title: "Voice typing", subtitle: "Typed wherever your cursor is",
                            isOn: $voice.enabled) {
                    Text("Engine").font(.system(size: 13))
                    HStack(spacing: 6) {
                        ForEach(VoiceTypingModel.Engine.allCases) { engine in
                            Pill(title: engine.title, selected: voice.engine == engine) { voice.engine = engine }
                        }
                    }
                    if voice.engine == .geminiLive {
                        Note(text: "Free with your own API key. Words appear while you speak; English and Bengali are detected by themselves, even mixed. Filler words are removed and punctuation added.")
                    } else {
                        Note(text: "Free, and needs no API key. It runs with Chrome speech recognition, so it needs Google Chrome installed: keep the \"MicFlow: voice typing\" tab open. Text comes without punctuation. If you close the Chrome tab, voice typing won't work.")
                        Text("It needs two different shortcut keys, one to type English and one for Bangla. It can't detect English and Bangla at the same time.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                FeatureCard(theme: theme, systemImage: "keyboard", title: "Keys", subtitle: "Click, then press the key to hold") {
                    if voice.engine == .chrome {
                        keyRow("Bengali", key: .bengali, name: voice.hotkeyName)
                        keyRow("English", key: .english, name: voice.englishHotkeyName)
                        PillButton(title: "Open the Model 2 tab", systemImage: "globe", action: voice.openChromePage)
                    } else {
                        keyRow("Hold to talk", key: .bengali, name: voice.hotkeyName)
                    }
                }
                FeatureCard(theme: theme, systemImage: "sparkles", title: "Clean-up", subtitle: "A moment after your words are pasted",
                            isOn: $voice.polish) {
                    Note(text: "Your words are pasted as heard, right away. Within about 2 seconds, misheard words are fixed from what the sentence means, punctuation and grammar corrected and filler words removed; sentences are never rewritten. Words you've edited stay yours, and if the text was already sent, only the clipboard gets the cleaned-up version.")
                    PillButton(title: voice.instructionsEnabled && !voice.yourInstructions.isEmpty ? "Your instructions: on" : "Add your instructions",
                               systemImage: "arrow.up.right", style: .cream, action: openDictionary)
                }
            } right: {
                if voice.engine == .geminiLive || voice.polish {
                    FeatureCard(theme: theme, systemImage: "key.fill", title: "API key", subtitle: "Kept in your Mac's Keychain") {
                        if voice.hasKey {
                            HStack {
                                Label("Saved in your Keychain", systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.cream)
                                Spacer()
                                PillButton(title: "Remove", style: .outline, action: voice.removeKey)
                            }
                            #if ADMIN
                            // Admin only: tries automatic setup even with a key saved (the old key keeps working).
                            if let account, account.isConfigured {
                                KeySetupButton(account: account, title: "Test: make a new key with Google")
                            }
                            #endif
                        } else {
                            if let account, account.isConfigured {
                                KeySetupButton(account: account)
                                Text("or paste a key").font(.system(size: 11)).foregroundStyle(Palette.greyOnDark)
                            }
                            HStack {
                                PillField(placeholder: "Paste your key", text: $keyDraft, secure: true, onSubmit: save)
                                PillButton(title: "Save", style: .cream, action: save)
                            }
                            Link("Get a free key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.cream)
                        }
                        Note(text: "On the free plan, the provider of this model may use what you say to improve their products, and people may review it, so don't dictate anything sensitive.")
                    }
                }
                FeatureCard(theme: theme, systemImage: "slider.horizontal.3", title: "Preferences",
                            subtitle: "\(voice.myWords.count) words · \(voice.mixUps.count) mix-ups") {
                    if !voice.myWords.isEmpty {
                        WordChips(words: Array(voice.myWords.prefix(8)), onDark: true, remove: nil)
                    }
                    PillButton(title: "Open Preferences", systemImage: "arrow.up.right", style: .cream, action: openDictionary)
                }
            }
        }
    }

    private func keyRow(_ title: String, key: VoiceTypingModel.VoiceKey, name: String?) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if voice.capturing == key {
                Text("Press a key…").font(.system(size: 12)).foregroundStyle(Palette.greyOnDark)
                PillButton(title: "Cancel", style: .outline, action: voice.cancelCapture)
            } else {
                PillButton(title: name ?? "Choose a key", systemImage: "command", style: .cream) { voice.captureHotkey(key) }
            }
        }
    }

    private func save() {
        guard !keyDraft.isEmpty else { return }
        voice.saveKey(keyDraft)
        keyDraft = ""
    }
}

/// Words as cream chips, with an × to remove when `remove` is given.
struct WordChips: View {
    let words: [String]
    var onDark = false
    let remove: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 6) {
                    Text(word).font(.system(size: 13, weight: .semibold))
                    if let remove {
                        Button { remove(word) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)) }
                            .buttonStyle(.plain)
                            .help("Remove \(word)")
                    }
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Palette.cream, in: Capsule())
            }
        }
    }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var voice: VoiceTypingModel
    let theme: HomeTheme
    @Environment(\.compactLayout) private var compact
    @State private var newWord = ""
    @State private var heard = ""
    @State private var meant = ""
    @State private var meaning = ""

    var body: some View {
        PageBody {
            HeroCard(kicker: "Preferences", title: "MicFlow, tuned to how you talk",
                     detail: "Tell clean-up about yourself, and add the words a normal dictionary doesn't know: brand names, industry jargon, local words, even made-up ones.",
                     chip: "\(voice.myWords.count) words", systemImage: "slider.horizontal.3") {
                EmptyView()
            }
            FeatureCard(theme: theme, systemImage: "person.text.rectangle.fill", title: "Your instructions",
                        subtitle: "Who you are and how you write, for clean-up", isOn: $voice.instructionsEnabled) {
                TextField("For example: I'm a UX designer, so I talk about Figma, wireframes, user flows and design systems. I write to clients, so keep a polite tone. My name is spelled Abdullah.",
                          text: $voice.yourInstructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(4...8)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
                    .disabled(!voice.instructionsEnabled)
                    .opacity(voice.instructionsEnabled ? 1 : 0.5)
                Note(text: "Clean-up uses this to understand your words: a designer's \"wireframe\" or an artist's \"gouache\". It's added after MicFlow's own rules, which always come first: change only misheard words, never whole sentences, and answer fast. Keep it short; up to 2,000 characters are used.")
            }
            (compact ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))) {
                WhitePanel {
                    HStack(alignment: .firstTextBaseline) {
                        Text("My words").font(.display(24))
                        Text("brands, jargon, local and made-up words").font(.system(size: 12)).foregroundStyle(Palette.greyOnLight)
                        Spacer()
                    }
                    if voice.myWords.isEmpty {
                        Text("No words yet. Add words a normal dictionary doesn't know, like your brand, product or team names, or words your community uses.").font(.system(size: 13))
                            .foregroundStyle(Palette.greyOnLight)
                    } else {
                        WordChips(words: voice.myWords, remove: voice.removeWord)
                    }
                    HStack {
                        PillField(placeholder: "Add a word", text: $newWord, onDark: false, onSubmit: addWord)
                        PillButton(title: "Add word", systemImage: "plus", style: .yellow, action: addWord)
                    }
                }
                FeatureCard(theme: theme, systemImage: "arrow.triangle.swap", title: "Mix-ups",
                            subtitle: "Fixed only where the sentence means it", isOn: $voice.fixMixUps) {
                    ForEach(voice.mixUps) { mixUp in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(mixUp.heard).font(.system(size: 13, weight: .bold))
                                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.pink)
                                    Text(mixUp.meant).font(.system(size: 13, weight: .bold))
                                }
                                if !mixUp.meaning.isEmpty { Note(text: mixUp.meaning) }
                            }
                            Spacer()
                            Button { voice.removeMixUp(mixUp) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)) }
                                .buttonStyle(.plain).help("Remove this mix-up")
                        }
                        .padding(12)
                        .background(theme.selected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    HStack(spacing: 6) {
                        PillField(placeholder: "Comes out as", text: $heard)
                        Image(systemName: "arrow.right").foregroundStyle(Palette.greyOnDark)
                        PillField(placeholder: "I meant", text: $meant)
                    }
                    PillField(placeholder: "Meaning (optional), e.g. the globe", text: $meaning, onSubmit: addMixUp)
                    PillButton(title: "Add mix-up", systemImage: "plus", style: .cream, action: addMixUp)
                    Note(text: "Clean-up fixes them only where the sentence means the other word.")
                }
                .frame(width: compact ? nil : 380)
            }
        }
    }

    private func addWord() {
        guard !newWord.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        voice.addWord(newWord)
        newWord = ""
    }

    private func addMixUp() {
        guard !heard.trimmingCharacters(in: .whitespaces).isEmpty, !meant.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        voice.addMixUp(heard: heard, meant: meant, meaning: meaning)
        heard = ""
        meant = ""
        meaning = ""
    }
}

// MARK: - Mouse

struct MousePage: View {
    @ObservedObject var model: BoostModel
    let theme: HomeTheme

    private var onCount: Int {
        [model.trackingSpeedEnabled, model.scrollDistanceEnabled, model.smoothScrollEnabled, model.swipeEnabled,
         model.mouseButtonsEnabled, model.middleClickEnabled].filter { $0 }.count
    }

    private var actions: [(value: SwipeGestureController.Action, title: String)] {
        SwipeGestureController.Action.allCases.map { ($0, $0.title) }
    }

    var body: some View {
        PageBody {
            HeroCard(kicker: "Mouse", title: onCount == 0 ? "Your mouse, your way" : "\(onCount) of 6 mouse features on",
                     detail: "Faster tracking, scrolling, swipe gestures, side buttons and middle click, for the Magic Mouse and regular mice.",
                     systemImage: "computermouse.fill") { EmptyView() }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "cursorarrow.motionlines", title: "Tracking speed", subtitle: "Past macOS's Fast",
                            isOn: $model.trackingSpeedEnabled) {
                    CreamSlider(title: "Speed", value: $model.trackingSpeed,
                                range: TrackingSpeedController.macOSFast...TrackingSpeedController.maximum, step: 0.1,
                                valueText: model.trackingSpeed == TrackingSpeedController.macOSFast ? "macOS Fast"
                                    : String(format: "+%.0f%%", (model.trackingSpeed / TrackingSpeedController.macOSFast - 1) * 100),
                                lowLabel: "macOS Fast", highLabel: "Faster")
                    switch model.trackingState {
                    case .running: Note(text: "Move it a step or two at a time.")
                    case .noMouse: Note(text: "No mouse found.", isError: true)
                    case .off: EmptyView()
                    }
                }
                FeatureCard(theme: theme, systemImage: "scroll", title: "Smooth scrolling", subtitle: "Pages ease into place",
                            isOn: $model.smoothScrollEnabled) {
                    CreamSlider(title: "Smoothness", value: $model.scrollSmoothness, range: 0...1, step: 0.1,
                                valueText: model.scrollSmoothness < 0.35 ? "Light" : model.scrollSmoothness < 0.75 ? "Medium" : "Very smooth")
                    if model.scrollState == .needsAccessibility { AccessibilityNotice(open: model.openAccessibilitySettings) }
                }
                FeatureCard(theme: theme, systemImage: "computermouse.fill", title: "Mouse buttons", subtitle: "Give any button an action",
                            isOn: $model.mouseButtonsEnabled) {
                    ForEach(MouseButtonController.Trigger.allCases) { trigger in
                        ActionPicker(label: trigger.title, selection: Binding(
                            get: { model.mouseButtonActions[trigger] ?? MouseAction.none },
                            set: { model.mouseButtonActions[trigger] = $0 }))
                    }
                    ForEach(model.buttonMappings) { mapping in
                        HStack(spacing: 6) {
                            ActionPicker(label: ButtonMapping.name(of: mapping.button), selection: Binding(
                                get: { mapping.action },
                                set: { model.setAction($0, forButton: mapping.button) }),
                                detail: mapping.action == .customShortcut
                                    ? (model.choosingKeysFor == mapping.button ? "Press keys…" : mapping.shortcut.map { "Keys: \($0.text)" } ?? "Choose keys…")
                                    : nil)
                            if mapping.action == .customShortcut {
                                Button { model.chooseKeys(forButton: mapping.button) } label: { Image(systemName: "keyboard") }
                                    .buttonStyle(.plain).help("Choose the keys")
                            }
                            Button { model.removeMouseButton(mapping.button) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .heavy))
                            }
                            .buttonStyle(.plain).help("Remove this button")
                        }
                    }
                    HStack {
                        if model.waitingForButton {
                            Text("Press the mouse button you want to set up…").font(.system(size: 12)).foregroundStyle(Palette.cream)
                            Spacer()
                            PillButton(title: "Cancel", style: .outline, action: model.cancelAddingMouseButton)
                        } else {
                            PillButton(title: "Add a button", systemImage: "plus", style: .cream, action: model.addMouseButton)
                            Spacer()
                        }
                    }
                    switch model.mouseButtonsState {
                    case .running: Note(text: "Click a button's action to search the list. A side button set to an action no longer goes Back/Forward. With a \"Hold Right\" combination on, right-click menus open when you release the button.")
                    case .needsAccessibility: AccessibilityNotice(open: model.openAccessibilitySettings)
                    case .off: EmptyView()
                    }
                }
            } right: {
                FeatureCard(theme: theme, systemImage: "arrow.up.and.down", title: "Scroll distance", subtitle: "How far each swipe goes",
                            isOn: $model.scrollDistanceEnabled) {
                    MultiplierCreamSlider(title: "Distance per swipe", value: $model.scrollDistance)
                    if model.scrollState == .needsAccessibility && !model.smoothScrollEnabled {
                        AccessibilityNotice(open: model.openAccessibilitySettings)
                    }
                }
                FeatureCard(theme: theme, systemImage: "hand.draw", title: "Swipe gestures", subtitle: "One finger on the Magic Mouse",
                            isOn: $model.swipeEnabled) {
                    PillMenu(label: "Swipe left", selection: $model.swipeLeftAction, options: actions)
                    PillMenu(label: "Swipe right", selection: $model.swipeRightAction, options: actions)
                    switch model.swipeState {
                    case .running: Note(text: "Swipe one finger quickly left or right across the mouse.")
                    case .needsAccessibility: AccessibilityNotice(open: model.openAccessibilitySettings)
                    case .noMagicMouse: Note(text: "No Magic Mouse found. Make sure it's turned on and connected.", isError: true)
                    case .shortcutOff:
                        Note(text: "Turn on \"Move left a space\" and \"Move right a space\" in Keyboard Shortcuts › Mission Control.", isError: true)
                        PillButton(title: "Open Keyboard Settings", style: .cream, action: model.openKeyboardShortcutSettings)
                    case .off: EmptyView()
                    }
                }
                FeatureCard(theme: theme, systemImage: "computermouse", title: "Middle click", subtitle: "Press the middle of the Magic Mouse",
                            isOn: $model.middleClickEnabled) {
                    CreamSlider(title: "Middle area", value: $model.middleZoneWidth, range: 0.15...0.5, step: 0.05,
                                valueText: "\(Int(model.middleZoneWidth * 100))% of the mouse")
                    switch model.middleClickState {
                    case .running: Note(text: "Click with one finger in the middle of your Magic Mouse.")
                    case .noMagicMouse: Note(text: "No Magic Mouse found. Make sure it's turned on and connected.", isError: true)
                    case .needsAccessibility: AccessibilityNotice(open: model.openAccessibilitySettings)
                    case .off: EmptyView()
                    }
                }
            }
        }
    }
}

// MARK: - Keyboard

struct KeyboardPage: View {
    @ObservedObject var model: BoostModel
    let theme: HomeTheme

    var body: some View {
        PageBody {
            HeroCard(kicker: "Keyboard",
                     title: model.keyRemapEnabled ? "\(model.keyRemaps.count) key\(model.keyRemaps.count == 1 ? "" : "s") remapped" : "Key remapping is off",
                     detail: "Swap Ctrl and the Windows key, turn F-keys into volume keys, or make a key switch your input language. Works on every keyboard.",
                     systemImage: "keyboard.fill") {
                PinkSwitch(isOn: $model.keyRemapEnabled)
                Text(model.keyRemapEnabled ? "On" : "Off").font(.system(size: 12, weight: .semibold))
            }
            if model.keyRemapEnabled {
                WhitePanel {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Remaps").font(.display(24))
                        Spacer()
                        PillButton(title: "Add remap", systemImage: "plus", style: .yellow) {
                            // A new row starts as Caps Lock → Escape; change both to taste.
                            model.keyRemaps.append(KeyRemap(from: 0x7_0000_0039, to: 0x7_0000_0029))
                        }
                    }
                    ForEach($model.keyRemaps) { $remap in
                        HStack(spacing: 10) {
                            PillMenu(selection: $remap.from, options: KeyChoice.keys.map { ($0.usage, $0.name) }, onDark: false)
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.pink)
                            PillMenu(selection: $remap.to, options: KeyChoice.targets.map { ($0.usage, $0.name) }, onDark: false)
                            Button { model.keyRemaps.removeAll { $0.id == remap.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .heavy))
                                    .frame(width: 30, height: 30).background(Color(hex: 0xF2F2F0), in: Circle())
                            }
                            .buttonStyle(.plain).help("Remove this remap")
                        }
                    }
                    if model.keyRemaps.isEmpty {
                        Text("No remaps yet. Click Add remap.").font(.system(size: 13)).foregroundStyle(Palette.greyOnLight)
                    }
                }
                status
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.keyRemapState {
        case .karabinerActive:
            DarkCard(theme: theme) { Note(text: "Karabiner-Elements is still active, so it's doing the remapping for now. These remaps take over once you uninstall it.", isError: true) }
        case .needsAccessibility:
            DarkCard(theme: theme) { AccessibilityNotice(open: model.openAccessibilitySettings) }
        case .noKeyboard:
            DarkCard(theme: theme) { Note(text: "No keyboard found.", isError: true) }
        case .running, .off:
            EmptyView()
        }
    }
}

// MARK: - Figma

struct FigmaPage: View {
    @ObservedObject var model: BoostModel
    let theme: HomeTheme

    var body: some View {
        PageBody {
            HeroCard(kicker: "Figma", title: model.figmaZoomEnabled ? "Swipe to zoom in Figma" : "Figma zoom is off",
                     detail: "In the Figma desktop app, swipe up or down on the mouse to zoom the canvas, without holding Control.",
                     chip: model.figmaZoomEnabled ? String(format: "%.2g× per swipe", model.figmaZoomAmount) : nil,
                     systemImage: "plus.magnifyingglass") { EmptyView() }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "plus.magnifyingglass", title: "Figma zoom", subtitle: "Swipe up or down to zoom",
                            isOn: $model.figmaZoomEnabled) {
                    MultiplierCreamSlider(title: "Zoom per swipe", value: $model.figmaZoomAmount)
                    switch model.figmaZoomState {
                    case .needsAccessibility: AccessibilityNotice(open: model.openAccessibilitySettings)
                    case .running, .off: EmptyView()
                    }
                }
            } right: {
                FeatureCard(theme: theme, systemImage: "hand.point.up.left.fill", title: "Moving around", subtitle: "Tips") {
                    Note(text: "Swipe sideways to move left and right. To move up and down, hold a middle click and drag, or hold the Space bar and drag.")
                    Note(text: "Only the Figma desktop app; Figma in a web browser and other apps scroll normally.")
                }
            }
        }
    }
}

// MARK: - Capture

struct CapturePage: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var imageHost: ImageHost
    let theme: HomeTheme
    @Environment(\.compactLayout) private var compact
    @State private var keyDraft = ""

    var body: some View {
        PageBody {
            HeroCard(kicker: "Capture", title: capture.isRecording ? "Recording your screen…" : "Capture anything on screen",
                     detail: capture.hasScreenPermission ? "Every capture is saved in Pictures › MicFlow Captures."
                        : "MicFlow needs Screen Recording permission. Turn it on, then quit and reopen MicFlow.",
                     chip: capture.shortcutsEnabled ? "\(capture.shortcut(for: .area).text) to capture" : nil, systemImage: "camera.viewfinder") {
                PillButton(title: "Capture Area", systemImage: "viewfinder", style: .orange) { capture.perform(.area) }
                PillButton(title: capture.isRecording ? "Stop Recording" : "Record Screen",
                           systemImage: capture.isRecording ? "stop.circle" : "record.circle", style: .ink) { capture.perform(.record) }
                if !capture.hasScreenPermission {
                    PillButton(title: "Screen Recording Settings", style: .ink, action: capture.openScreenRecordingSettings)
                }
            }
            WhitePanel {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tools").font(.display(24))
                    if !compact {
                        Text("click, or use the shortcut").font(.system(size: 12)).foregroundStyle(Palette.greyOnLight)
                    }
                    Spacer()
                    PillButton(title: compact ? "Folder" : "Captures folder", systemImage: "folder", style: .ink, action: capture.openFolder)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: compact ? 2 : 4), spacing: 10) {
                    ForEach(CaptureAction.allCases) { action in
                        tile(action.title, action.systemImage, capture.shortcutsEnabled && capture.shortcut(for: action).keyCode >= 0 ? capture.shortcut(for: action).text : nil) { capture.perform(action) }
                    }
                    tile("Mark Up an Image", "pencil.tip.crop.circle", nil, capture.openImage)
                }
            }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "gearshape.fill", title: "Options") {
                    CheckRow(title: "Copy screenshots to the clipboard", isOn: $capture.copyToClipboard)
                    CheckRow(title: "Record the microphone with videos", isOn: $capture.recordMicrophone)
                    CheckRow(title: "Keyboard shortcuts", isOn: $capture.shortcutsEnabled)
                    HStack(spacing: 6) {
                        Text("Self-timer").font(.system(size: 13))
                        Spacer()
                        ForEach([3, 5, 10], id: \.self) { seconds in
                            Pill(title: "\(seconds) s", selected: capture.timerSeconds == seconds) { capture.timerSeconds = seconds }
                        }
                    }
                    Note(text: "Capture Text reads text on this Mac; nothing is uploaded.")
                }
                FeatureCard(theme: theme, systemImage: "command", title: "Shortcuts", subtitle: "Click one, then press the new keys") {
                    ForEach(CaptureAction.allCases) { action in
                        HStack {
                            Image(systemName: action.systemImage).font(.system(size: 12)).frame(width: 18)
                            Text(action.title).font(.system(size: 13))
                            Spacer()
                            if capture.choosingShortcut == action {
                                Text("Press keys…").font(.system(size: 12)).foregroundStyle(Palette.greyOnDark)
                                PillButton(title: "Cancel", style: .outline, action: capture.cancelChoosingShortcut)
                            } else {
                                let shortcut = capture.shortcut(for: action)
                                PillButton(title: shortcut.keyCode >= 0 ? shortcut.text : "Choose", style: .cream) {
                                    capture.chooseShortcut(for: action)
                                }
                            }
                        }
                    }
                    if let message = capture.shortcutMessage { Note(text: message) }
                    HStack {
                        Note(text: "Use ⌘, ⌥ or ⌃ with a key, or an F key. Esc cancels.")
                        Spacer()
                        PillButton(title: "Reset", style: .outline, action: capture.resetShortcuts)
                    }
                }
            } right: {
                FeatureCard(theme: theme, systemImage: "link", title: "Share links",
                            subtitle: imageHost.hasKey ? "Uploads go to ImgBB, link-only" : "Get a link to any screenshot") {
                    if imageHost.hasKey {
                        Note(text: "Click Upload on a screenshot and its link is copied. Only people with the link can see it; nothing lists your uploads. Videos stay on your Mac.")
                        HStack(spacing: 6) {
                            Text("Copy as").font(.system(size: 13))
                            Spacer()
                            ForEach(ImageHost.LinkStyle.allCases) { style in
                                Pill(title: style.title, selected: imageHost.linkStyle == style) { imageHost.linkStyle = style }
                            }
                        }
                        HStack {
                            Label("Key saved in your Keychain", systemImage: "checkmark.seal.fill").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.cream)
                            Spacer()
                            PillButton(title: "Remove key", style: .outline, action: imageHost.removeKey)
                        }
                    } else {
                        Note(text: "Uploads go to ImgBB, a free image host. Make a free account there, copy your API key and paste it here. Each picture gets a link only you share.")
                        Link("Get a free ImgBB key", destination: ImageHost.keyPage)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.cream)
                        HStack {
                            PillField(placeholder: "Paste your ImgBB key", text: $keyDraft, secure: true) { saveKey() }
                            PillButton(title: "Save", style: .cream, action: saveKey)
                        }
                    }
                }
            }
        }
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        imageHost.saveKey(keyDraft)
        keyDraft = ""
    }

    private func tile(_ title: String, _ systemImage: String, _ shortcut: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Circle().fill(Palette.cream).frame(width: 36, height: 36)
                    .overlay(Image(systemName: systemImage).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.pink))
                Text(title).font(.system(size: 13, weight: .bold)).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(shortcut ?? " ").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.greyOnLight)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(Color(hex: 0xF2F2F0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mouse actions

/// A pill that opens a searchable list of every mouse action, grouped like BetterTouchTool's.
struct ActionPicker: View {
    var label: String?
    @Binding var selection: MouseAction
    var detail: String?
    @State private var open = false
    @State private var search = ""

    private var matches: [MouseAction] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return MouseAction.allCases.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.group.lowercased().contains(query)
        }
    }

    var body: some View {
        HStack {
            if let label { Text(label).font(.system(size: 13)).lineLimit(1); Spacer() }
            Button { search = ""; open = true } label: {
                HStack(spacing: 8) {
                    Text(detail ?? selection.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: label == nil ? .infinity : 230)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search actions", text: $search)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(MouseAction.groups, id: \.self) { group in
                                let items = matches.filter { $0.group == group }
                                if !items.isEmpty {
                                    Text(group.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                        .padding(.top, 6).padding(.leading, 12)
                                    ForEach(items) { action in
                                        Button {
                                            selection = action
                                            open = false
                                        } label: {
                                            HStack {
                                                Text(action.title).font(.system(size: 13, weight: action == selection ? .semibold : .regular))
                                                Spacer()
                                                if action == selection { Image(systemName: "checkmark").foregroundStyle(Palette.pink) }
                                            }
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(action == selection ? Palette.cream : .clear, in: Capsule())
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if matches.isEmpty {
                                Text("No action matches.").foregroundStyle(.secondary).padding(12)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(width: 300, height: 380)
                .environment(\.colorScheme, .light)
            }
        }
    }
}

/// "Set it up for me": sign in with Google, and MicFlow makes the key in the user's account.
struct KeySetupButton: View {
    @ObservedObject var account: Account
    var title = "Set it up for me with Google"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PillButton(title: account.isWorking ? "Waiting for Google…" : title,
                       systemImage: "sparkles", style: .cream) { account.signIn(setUpKey: true) }
            if let message = account.keySetupMessage {
                Note(text: message, isError: message.hasPrefix("Couldn't"))
            }
            if let fix = account.keySetupFixURL {
                Link("Accept the terms", destination: fix)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.cream)
            }
        }
    }
}
