import AppKit
import SwiftUI

/// Whether voice typing still needs its model's key (Model 1 without one). Home then shows the two
/// ways to set it up instead of the dashboard, and every other page shows `VoiceSetupBanner`.
extension VoiceTypingModel {
    var needsKeySetup: Bool {
        #if ADMIN
        // Admin QA: MICFLOW_PREVIEW_NOKEY=1 shows the no-key screens without removing the saved key.
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_NOKEY"] != nil { return engine == .geminiLive }
        #endif
        return engine == .geminiLive && (!hasKey || keyRefused)
    }

    /// The saved key works no more (its account's free plan is off).
    var keyRefused: Bool {
        #if ADMIN
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_KEYOFF"] != nil { return true }
        #endif
        return keyFreePlanOff
    }
}

extension Account {
    /// The Voice Typing tab shows only while signed in (always, in a build without accounts).
    var showsVoiceTab: Bool { !isConfigured || signedInForVoice }

    /// Signed in with Google, which voice typing (both models) needs.
    var signedInForVoice: Bool {
        #if ADMIN
        // Admin QA: MICFLOW_PREVIEW_SIGNEDOUT=1 shows the signed-out Home without signing out.
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_SIGNEDOUT"] != nil { return false }
        #endif
        return isSignedIn
    }
}

/// Whether Home shows the setup instead of the dashboard: not signed in yet, or Model 1 without a
/// working key.
@MainActor
func voiceNeedsSetup(_ voice: VoiceTypingModel, _ account: Account) -> Bool {
    (account.isConfigured && !account.signedInForVoice) || voice.needsKeySetup
}

/// Home until voice typing is ready. Signed out: a heading, one line, and Google's own big
/// "Sign in with Google" button, which also makes the key. Progress and any problem show right
/// under it; pasting your own key only appears once Google wouldn't make one.
struct HomeKeySetup: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account
    @ObservedObject var flow: KeySetupFlow
    let theme: HomeTheme

    init(voice: VoiceTypingModel, account: Account, theme: HomeTheme) {
        self.voice = voice
        self.account = account
        self.flow = account.keySetup
        self.theme = theme
    }

    private var signedIn: Bool { account.signedInForVoice }
    private var showPaste: Bool { signedIn && (flow.hasFailed || voice.keyRefused) }
    private var showButton: Bool { flow.stage == .idle || flow.hasFailed }

    /// Nothing under the yellow card yet: it fills the page, its content centred.
    private var alone: Bool { flow.stage == .idle && !showPaste }

    var body: some View {
        GeometryReader { geometry in
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                VStack(spacing: 18) {
                    PageSticker(systemImage: "waveform").padding(.bottom, 4)
                    Text(title).font(.display(40)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                        .foregroundStyle(Palette.ink.opacity(0.75)).frame(maxWidth: 560)
                        .fixedSize(horizontal: false, vertical: true)
                    if showButton {
                        GoogleSignInButton(title: signedIn ? "Continue with Google" : "Sign in with Google", size: .large,
                                           isWorking: account.isWorking, action: start)
                            .padding(.top, 6)
                    }
                    if let message = account.message, flow.stage == .idle {
                        Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.white.opacity(0.6), in: Capsule())
                    }
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 40).padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: alone ? geometry.size.height - 4 : nil)
                .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                if flow.stage != .idle {
                    DarkCard(theme: theme) {
                        KeySetupStatus(flow: flow)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if showPaste {
                    FeatureCard(theme: theme, systemImage: "key.fill", title: "Or paste your own key",
                                subtitle: "You're signed in; only the key is missing") {
                        PasteKey(voice: voice)
                        Note(text: "Your key is kept in your Mac's Keychain, and your account keeps a locked (encrypted) copy that only MicFlow, signed in as you, can open.")
                    }
                }
            }
            .padding(.bottom, 4)
        }
        }
    }

    private var title: String {
        if voice.keyRefused { return "Your key needs replacing" }
        return signedIn ? "One more step: your voice key" : "Login with Google to start using voice typing"
    }

    private var detail: String {
        if voice.keyRefused {
            return "Google stopped accepting the key from your Google account. Set it up again, maybe with a Google account you use regularly, or paste your own key."
        }
        return signedIn ? "You're signed in. Let MicFlow make your free voice key with Google; it takes about a minute."
            : "Logging in turns on voice typing and saves all your preferences, instructions and settings to your account. Your API key is made for you automatically, so you don't have to create one."
    }

    private func start() {
        // A working key already on this Mac, or Model 2 (no key): a plain sign-in is enough,
        // without the Google Cloud permission.
        if !signedIn, !voice.needsKeySetup {
            account.signIn(setUpKey: false)
        } else {
            flow.begin()
        }
    }
}

/// The paste route: open the key page, paste, save (checked first).
private struct PasteKey: View {
    @ObservedObject var voice: VoiceTypingModel
    @State private var draft = ""
    @State private var checking = false
    @State private var problem: String?

    private static let keyPage = URL(string: "https://aistudio.google.com/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                step(1, "Open the key page and sign in")
                Spacer()
                PillButton(title: "Open the key page", systemImage: "arrow.up.right", style: .outline) { NSWorkspace.shared.open(Self.keyPage) }
            }
            step(2, "Click Create API key, then copy the key")
            step(3, "Paste it here")
            HStack(spacing: 8) {
                PillField(placeholder: "Paste your key", text: $draft, secure: true, onSubmit: save)
                PillButton(title: checking ? "Checking…" : "Save", style: .cream, action: save)
                    .disabled(checking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking that the key works…").font(.system(size: 12)).foregroundStyle(Palette.greyOnDark)
                }
            }
            if let problem { Note(text: "That key didn't work: \(problem)", isError: true) }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.ink)
                .frame(width: 22, height: 22).background(Palette.cream, in: Circle())
            Text(text).font(.system(size: 12.5, weight: .semibold))
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        problem = nil
        Task {
            let result = await voice.saveKeyChecked(key)
            checking = false
            if let result { problem = result } else { draft = ""; voice.enabled = true }
        }
    }
}

/// On every page but Home until voice typing is ready: one line and a button back to Home.
struct VoiceSetupBanner: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account
    let openHome: () -> Void

    var body: some View {
        if voiceNeedsSetup(voice, account) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.white)
                    .frame(width: 38, height: 38).background(Palette.pink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.signedInForVoice ? "Finish setting up voice typing" : "Sign in to use voice typing").font(.system(size: 15, weight: .bold))
                    Text(voice.keyRefused ? "Google stopped accepting your key. Set it up again on Home."
                         : account.signedInForVoice ? "One more step on Home: MicFlow makes your free voice key (about a minute)."
                         : "Sign in with Google on Home: MicFlow sets everything up and saves your settings to your account.")
                        .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer()
                PillButton(title: account.signedInForVoice ? "Set up" : "Sign in", systemImage: "arrow.right", style: .ink, action: openHome)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.pink, lineWidth: 2))
        }
    }
}
