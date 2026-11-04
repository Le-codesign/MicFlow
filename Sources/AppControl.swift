import AppKit
import SwiftUI

/// The banner at the top of Home when a new version is out. Its words come from the CMS; versions
/// older than the CMS's minimum get the stronger "out of date" words.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @ObservedObject var store: SiteContentStore

    var body: some View {
        if case .available(let version, _) = updater.state {
            let notice = store.content.update ?? .standard
            let outdated = notice.minimumVersion.map { Updater.isNewer($0, than: updater.currentVersion) } ?? false
            HStack(spacing: 14) {
                Image(systemName: outdated ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(outdated ? Palette.white : Palette.pink)
                    .frame(width: 40, height: 40)
                    .background(outdated ? Palette.orange : Palette.cream, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(outdated ? notice.outdatedTitle ?? notice.title : notice.title)
                        .font(.system(size: 15, weight: .bold))
                    Text((outdated ? notice.outdatedSubtitle ?? notice.subtitle : notice.subtitle) + "  (MicFlow \(version))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink.opacity(0.7))
                        .lineLimit(2)
                    if let problem = updater.lastError {
                        HStack(spacing: 6) {
                            Text(problem).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Link("Download", destination: URL(string: "https://github.com/\(SiteContentStore.repository)/releases/latest")!)
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                }
                Spacer()
                PillButton(title: "Update now", systemImage: "arrow.down.circle", style: .ink, action: updater.install)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(outdated ? Palette.yellow : Palette.mint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if case .installing(let step) = updater.state {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(step).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(14)
            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Covers the whole window while your blocking pop-up is on. It can't be closed; it goes away by
/// itself once its condition is met (or you turn it off in the CMS).
struct BlockerView: View {
    let blocker: SiteContent.Blocker
    @ObservedObject var updater: Updater
    var signIn: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.white)
                    .frame(width: 48, height: 48).background(Palette.orange, in: Circle())
                Text(blocker.title).font(.display(30))
                if !blocker.message.isEmpty {
                    Text(blocker.message).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
                Text("MicFlow's shortcuts and features are paused until then.")
                    .font(.system(size: 12)).foregroundStyle(Palette.greyOnLight)
                HStack(spacing: 8) {
                    switch blocker.condition {
                    case .update:
                        if case .installing(let step) = updater.state {
                            ProgressView().controlSize(.small)
                            Text(step).font(.system(size: 13))
                        } else {
                            PillButton(title: "Update now", systemImage: "arrow.down.circle", style: .ink) {
                                if case .available = updater.state { updater.install() } else { updater.check() }
                            }
                        }
                    case .signIn:
                        if let signIn { PillButton(title: "Sign in with Google", systemImage: "person.crop.circle", style: .ink, action: signIn) }
                    case .always:
                        EmptyView()
                    }
                    if let title = blocker.buttonTitle, !title.isEmpty, let link = blocker.buttonLink.flatMap(URL.init(string:)) {
                        PillButton(title: title, systemImage: "arrow.up.right", style: .orange) { NSWorkspace.shared.open(link) }
                    }
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(28)
            .frame(width: 460, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(radius: 30)
        }
    }
}

/// On Home, while voice typing can't work yet: what's missing, with the button that fixes it.
struct SetupBanner: View {
    @ObservedObject var voice: VoiceTypingModel
    let openVoice: () -> Void

    var body: some View {
        if voice.enabled, voice.needsAccessibility {
            banner("Allow MicFlow in Accessibility",
                   "Without it, MicFlow can't hear your voice key or type for you.",
                   button: "Open Accessibility Settings", action: voice.openAccessibilitySettings)
        } else if voice.enabled, voice.engine == .geminiLive, !voice.hasKey {
            banner("Finish setting up voice typing",
                   "Add an API key, or let MicFlow set one up for you with Google.",
                   button: "Set up voice typing", action: openVoice)
        }
    }

    private func banner(_ title: String, _ detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.white)
                .frame(width: 40, height: 40).background(Palette.orange, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7))
            }
            Spacer()
            PillButton(title: button, systemImage: "arrow.right", style: .ink, action: action)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
