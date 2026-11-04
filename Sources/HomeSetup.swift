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
        return engine == .geminiLive && !hasKey
    }
}

/// Home, until voice typing has a key: the two ways to get one, side by side, with what's good and
/// what to keep in mind about each.
struct HomeKeySetup: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.white)
                        .frame(width: 46, height: 46).background(Palette.pink, in: Circle())
                    Text("Set up voice typing").font(.display(34))
                    Text("Voice typing needs a free key for its voice model. Pick one of the two ways below; you only do this once.")
                        .font(.system(size: 14)).foregroundStyle(Palette.ink.opacity(0.7))
                }

                HStack(alignment: .top, spacing: 14) {
                    if account.isConfigured {
                        SetupOption(number: 1, badge: "Easiest", title: "Set it up for me with Google",
                                    good: "No copying or pasting. MicFlow creates a free key in your own Google account and saves it for you, in about a minute.",
                                    mind: "Google asks you to allow Google Cloud access and shows a warning screen first (Google's review of MicFlow isn't finished). You also accept Google's terms once: one or two pages.") {
                            HStack(spacing: 10) {
                                PillButton(title: account.isWorking ? "Waiting for Google…" : "Set it up for me",
                                           systemImage: "sparkles", style: .ink, action: account.keySetup.begin)
                                Button("See the steps first") { account.keySetup.showGuide = true }
                                    .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                            }
                            KeySetupStatus(flow: account.keySetup)
                        }
                    }
                    SetupOption(number: account.isConfigured ? 2 : 1, badge: "Most private", title: "Create a key yourself and paste it",
                                good: "MicFlow never asks for access to your Google account. You make the key and stay in control of it.",
                                mind: "A few more steps: open the key page, sign in, click Create API key, copy the key and paste it here.") {
                        PasteKey(voice: voice)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 16)).foregroundStyle(Palette.mintText)
                    Text("Either way, your key is saved safely in your Mac's Keychain. It's only used from this Mac to talk to the voice model; we can't see your key or use it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 6) {
                    Text("Rather not use a key?").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
                    Button("Use Model 2, which needs none") { voice.engine = .chrome }
                        .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(28)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

/// One way to set up: its number and title, what's good, what to keep in mind, then its controls.
private struct SetupOption<Content: View>: View {
    let number: Int
    let badge: String
    let title: String
    let good: String
    let mind: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(number)").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.white)
                    .frame(width: 26, height: 26).background(Palette.orange, in: Circle())
                Text(badge).font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.yellow.opacity(0.35), in: Capsule())
            }
            Text(title).font(.system(size: 18, weight: .bold))
            point("hand.thumbsup.fill", Palette.mintText, good)
            point("exclamationmark.circle.fill", Palette.orange, mind)
            Divider()
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(hex: 0xF7F5EF), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
    }

    private func point(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
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
            step(1, "Open the key page and sign in")
            PillButton(title: "Open the key page", systemImage: "arrow.up.right", style: .cream) { NSWorkspace.shared.open(Self.keyPage) }
            step(2, "Click Create API key, then copy the key")
            step(3, "Paste it here")
            HStack(spacing: 8) {
                PillField(placeholder: "Paste your key", text: $draft, secure: true, onDark: false, onSubmit: save)
                PillButton(title: checking ? "Checking…" : "Save", style: .ink, action: save)
                    .disabled(checking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking that the key works…").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
                }
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.pink)
                    Text("That key didn't work: \(problem)").font(.system(size: 12)).foregroundStyle(Palette.pink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.ink.opacity(0.6))
                .frame(width: 18, height: 18).background(Color.black.opacity(0.07), in: Circle())
            Text(text).font(.system(size: 12, weight: .semibold))
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
                    Text("Voice typing needs a key first: sign in with Google, or paste a key you made. It takes about a minute.")
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
