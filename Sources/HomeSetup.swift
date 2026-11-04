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

/// Home, until voice typing has a key: the same parts as every other page (the yellow hero, then
/// dark feature cards), with the two ways to get a key side by side and what's good and what to
/// keep in mind about each.
struct HomeKeySetup: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account
    let theme: HomeTheme

    var body: some View {
        PageBody {
            HeroCard(kicker: "Get started",
                     title: voice.keyRefused ? "Your key needs replacing" : "Set up voice typing in about a minute",
                     detail: voice.keyRefused
                        ? "Google turned off the free plan for the Google account your saved key was made in, so it refuses every request. Make a new key below with a Google account you've used for a while."
                        : "Voice typing needs a free key for its voice model. Pick one of the two ways below; you only do this once.",
                     chip: voice.keyRefused ? "Key refused" : "Not set up yet", systemImage: "waveform") {
                if account.isConfigured {
                    PillButton(title: "See the steps first", systemImage: "list.number", style: .ink) { account.keySetup.showGuide = true }
                }
            }
            CardColumns {
                if account.isConfigured {
                    FeatureCard(theme: theme, systemImage: "sparkles", title: "Set it up for me with Google",
                                subtitle: "Way 1 · Easiest") {
                        ProsCons(good: "No copying or pasting. MicFlow creates a free key in your own Google account and saves it for you.",
                                 mind: "Google asks for Google Cloud access and shows a warning screen first, because its review of MicFlow isn't finished. You also accept Google's terms once: one or two pages.")
                        PillButton(title: account.isWorking ? "Waiting for Google…" : "Set it up for me", systemImage: "sparkles",
                                   style: .orange, action: account.keySetup.begin)
                        KeySetupStatus(flow: account.keySetup)
                    }
                } else {
                    pasteCard
                }
                safeCard
            } right: {
                if account.isConfigured { pasteCard }
            }
        }
    }

    private var safeCard: some View {
        FeatureCard(theme: theme, systemImage: "lock.shield.fill", title: "Safe in your Keychain",
                    subtitle: "Whichever way you pick") {
            Note(text: "Your key is saved in your Mac's Keychain. It's only used from this Mac to talk to the voice model; we can't see your key or use it.")
            Note(text: "Use a Google account you've had for a while: Google may not give brand-new accounts the free plan, and no app can change that.")
            HStack(spacing: 10) {
                Text("Rather not use a key?").font(.system(size: 12)).foregroundStyle(Palette.greyOnDark)
                PillButton(title: "Use Model 2", systemImage: "waveform", style: .outline) { voice.engine = .chrome }
            }
        }
    }

    private var pasteCard: some View {
        FeatureCard(theme: theme, systemImage: "key.fill", title: "Create a key yourself and paste it",
                    subtitle: account.isConfigured ? "Way 2 · Most private" : "Takes about two minutes") {
            ProsCons(good: "MicFlow never asks for access to your Google account. You make the key and stay in control of it.",
                     mind: "A few more steps: open the key page, sign in, click Create API key, copy the key and paste it here.")
            PasteKey(voice: voice)
        }
    }
}

/// What's good (mint) and what to keep in mind (orange), one line each.
private struct ProsCons: View {
    let good: String
    let mind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("hand.thumbsup.fill", Palette.mintText, "Good", good)
            row("exclamationmark", Palette.orange, "Keep in mind", mind)
        }
    }

    private func row(_ icon: String, _ color: Color, _ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Image(systemName: icon).font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.greyOnDark)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// On every page but Home while voice typing has no key: one line and a button back to Home, where
/// the two ways to set it up are.
struct VoiceSetupBanner: View {
    @ObservedObject var voice: VoiceTypingModel
    let openHome: () -> Void

    var body: some View {
        if voice.needsKeySetup {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.white)
                    .frame(width: 38, height: 38).background(Palette.pink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your voice model").font(.system(size: 15, weight: .bold))
                    Text(voice.keyRefused ? "Your saved key can't be used any more. Set up a new one on Home: it takes about a minute."
                         : "Voice typing needs a key first: sign in with Google, or paste a key you made. It takes about a minute.")
                        .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer()
                PillButton(title: "Set up", systemImage: "arrow.right", style: .ink, action: openHome)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.pink, lineWidth: 2))
        }
    }
}
