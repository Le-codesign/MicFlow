import AppKit
import SwiftUI

/// "Set it up for me with Google", from the click to a saved key: the guide that explains Google's
/// screens first, the sign-in, the key itself, and (when Google asks for it) the terms step, which
/// MicFlow keeps checking by itself so the page updates as soon as the terms are accepted.
@MainActor
final class KeySetupFlow: ObservableObject {
    enum Stage: Equatable {
        case idle
        case working(String)
        /// Google wants the account to accept the model's terms once.
        case needsTerms
        /// The Google Cloud box wasn't ticked on Google's permission screen.
        case missingPermission
        case failed(String)
        /// Google switched off the free plan for this Google account (its keys need billing).
        case freePlanOff
        case done
    }

    @Published private(set) var stage = Stage.idle
    @Published var showGuide = false
    /// The Google account the key is being made in (to open Google's pages in that account).
    @Published private(set) var email: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    /// Checking by itself every few seconds (stops after 15 minutes).
    @Published private(set) var isWatching = false
    /// Which of Google's terms the account still has to accept (Google names it each time).
    @Published private(set) var termsID: String?
    /// How many terms pages were accepted while waiting (Google can ask for two in a row).
    @Published private(set) var acceptedTerms = 0
    /// Just went from one terms page to the next: the card says so in green for a while.
    @Published private(set) var justAccepted = false

    /// Set by the app.
    var signIn: () -> Void = {}
    var save: (String) async -> String? = { _ in "Not ready" }
    var afterSave: () -> Void = {}
    var fallbackEmail: () -> String? = { nil }
    var hasKey: () -> Bool = { false }
    var useModel2: () -> Void = {}

    static let skipGuideKey = "skipGoogleKeyGuide"
    private var token: String?
    private var tokenExpires = Date.distantPast
    private var project: String?
    private var termsURL = KeyProvisioner.termsPage
    private var watch: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    init() {
        // Coming back to MicFlow from the browser checks straight away.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isWatching == true { self?.wakeUp() } }
        }
    }

    #if ADMIN
    /// Admin QA: `MICFLOW_PREVIEW_KEYSETUP=terms|tick` shows that state without signing in.
    func previewIfAsked() {
        switch ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_KEYSETUP"] {
        case "terms": email = "someone@gmail.com"; termsID = "universal"; stage = .needsTerms
        case "terms2": email = "someone@gmail.com"; termsID = "generative-language-api"; acceptedTerms = 1; justAccepted = true; stage = .needsTerms
        case "freeplan": stage = .freePlanOff
        case "tick": stage = .missingPermission
        default: break
        }
    }
    #endif

    var hasValidToken: Bool { token != nil && tokenExpires.timeIntervalSinceNow > 60 }

    /// The button: the guide first (unless turned off), then Google.
    func begin() {
        if UserDefaults.standard.bool(forKey: Self.skipGuideKey) { continueToGoogle() } else { showGuide = true }
    }

    /// Back to the start (e.g. after switching to Model 2).
    func reset() {
        stop()
        stage = .idle
        justAccepted = false
    }

    func continueToGoogle() {
        showGuide = false
        stop()
        stage = .idle
        signIn()
    }

    /// The sign-in finished. `token` is nil when Google didn't hand over access.
    func received(token: String?) {
        stop()
        guard let token else {
            stage = .failed("Google didn't give MicFlow access to set up the key. Try again.")
            return
        }
        self.token = token
        tokenExpires = Date().addingTimeInterval(50 * 60)
        project = nil
        termsID = nil
        acceptedTerms = 0
        Task { await firstRun() }
    }

    private func firstRun() async {
        guard let token else { return }
        stage = .working("Checking what Google allowed…")
        if let info = await KeyProvisioner.tokenInfo(token) {
            email = info.email ?? fallbackEmail()
            if let seconds = info.expiresIn { tokenExpires = Date().addingTimeInterval(seconds) }
            guard info.scopes.contains(Account.cloudScope) else {
                stage = .missingPermission
                return
            }
        } else {
            email = fallbackEmail()
        }
        await attempt()
    }

    /// One try at making the key. Returns whether to keep checking.
    @discardableResult
    private func attempt() async -> Bool {
        guard let token, hasValidToken else {
            stop()
            return false
        }
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }
        do {
            let showProgress = stage != .needsTerms
            let key = try await KeyProvisioner.createKey(googleToken: token, project: project) { step in
                guard showProgress else { return }
                Task { @MainActor [weak self] in self?.stage = .working(step) }
            }
            stage = .working("Checking your new key…")
            if let problem = await save(key) {
                stop()
                stage = problem == ProviderName.freePlanOff ? .freePlanOff
                    : .failed("The new key didn't work yet (\(problem)). Try again in a minute.")
                return false
            }
            stage = .done
            stop()
            afterSave()
            return false
        } catch let failure as KeyProvisioner.Failure where failure.needsTerms {
            project = failure.project ?? project
            termsURL = failure.fixURL ?? KeyProvisioner.termsPage
            let id = failure.termsID ?? "cloud"
            if stage == .needsTerms, let previous = termsID, previous != id {
                // The first page went through and Google wants the next one: say so clearly, and
                // open it straight away (both pages look almost the same).
                acceptedTerms += 1
                termsID = id
                justAccepted = true
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.open(termsPage)
            }
            termsID = id
            if stage != .needsTerms { stage = .needsTerms; startWatching() }
            return true
        } catch where stage == .needsTerms && error is URLError {
            // Offline for a moment while waiting: keep checking.
            return true
        } catch {
            stage = .failed(error.localizedDescription)
            stop()
            return false
        }
    }

    // MARK: Terms

    /// Google's terms page, opened in the same Google account the user signed in with.
    var termsPage: URL { KeyProvisioner.page(termsURL, as: email) }

    func openTerms() {
        justAccepted = false
        NSWorkspace.shared.open(termsPage)
        if !isWatching { startWatching() }
    }

    /// "Check again": with Google's access still valid, no new sign-in is needed.
    func checkNow() {
        guard hasValidToken else { continueToGoogle(); return }
        if isWatching { wakeUp() } else { startWatching(immediately: true) }
    }

    /// Every 5 seconds for 2 minutes, then every 20 seconds, for 15 minutes in all; one light
    /// request each time (Google's own API, with the user's own access).
    private func startWatching(immediately: Bool = false) {
        watch?.cancel()
        isWatching = true
        let started = Date()
        let hadKey = hasKey()
        watch = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                // A key pasted by hand meanwhile wins: stop, and never replace it.
                if let self, !hadKey, self.hasKey() { self.stage = .idle; self.stop(); return }
                let elapsed = Date().timeIntervalSince(started)
                guard elapsed < 15 * 60 else { break }
                if !(first && immediately) { await self?.sleep(seconds: elapsed < 120 ? 5 : 20) }
                first = false
                guard !Task.isCancelled, let self else { return }
                if !hadKey, self.hasKey() { self.stage = .idle; self.stop(); return }
                guard await self.attempt() else { return }
            }
            if !Task.isCancelled { self?.isWatching = false }
        }
    }

    private var wakeID = 0
    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake?.resume()
            wakeID += 1
            let id = wakeID
            wake = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { continuation.resume(); return }
                    if self.wakeID == id { self.wakeUp() }
                }
            }
        }
    }

    private func wakeUp() {
        guard let wake else { return }
        self.wake = nil
        wake.resume()
    }

    private func stop() {
        watch?.cancel()
        watch = nil
        isWatching = false
        wakeUp()
    }
}

// MARK: - Guide

/// The pop-up before Google's sign-in: what's about to happen and the two screens to get past.
struct GoogleKeyGuide: View {
    @ObservedObject var flow: KeySetupFlow
    @AppStorage(KeySetupFlow.skipGuideKey) private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.ink)
                    .frame(width: 40, height: 40).background(Palette.yellow, in: Circle())
                Text("Let MicFlow set up your key").font(.display(26))
                Text("Sign in with Google and MicFlow creates your free API key in your own Google account and saves it for you, so you never copy or paste a key. It takes about a minute. Google shows two screens on the way; here's what to click.")
                    .font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GuideStep(number: 1, image: "Guide-Advanced",
                              title: "Google says it hasn't verified MicFlow: click Advanced, then \"Go to … (unsafe)\"",
                              detail: "You see this because Google's review of MicFlow isn't finished yet. MicFlow only uses this access to make your key.")
                    GuideStep(number: 2, image: "Guide-Tick",
                              title: "Tick this box. This is the important one",
                              detail: "It lets MicFlow create the key in your Google account. Without the tick, setup can't finish. Then click Continue at the bottom.")
                    GuideStep(number: 3, image: "Guide-Accept",
                              title: "If Google asks, accept its terms (one click per page)",
                              detail: "Only the first time, and sometimes two pages in a row. MicFlow opens each page in the same Google account and notices by itself once you've clicked Accept.")
                }
                .padding(.horizontal, 24).padding(.bottom, 8)
            }

            Divider()
            HStack(spacing: 10) {
                Toggle("Don't show this again", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Button("Cancel") { flow.showGuide = false }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: "Continue with Google", systemImage: "arrow.right", style: .ink, action: flow.continueToGoogle)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .foregroundStyle(Palette.ink)
        .frame(width: 560, height: 640)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

private struct GuideStep: View {
    let number: Int
    let image: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.white)
                    .frame(width: 22, height: 22).background(Palette.orange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GuideImage(name: image)
        }
    }
}

struct GuideImage: View {
    let name: String
    var maxHeight: CGFloat = 260

    var body: some View {
        if let image = Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(NSImage.init(contentsOf:)) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
        }
    }
}

/// Puts the guide on screen whenever the flow asks for it.
struct KeyGuideHost: View {
    @ObservedObject var flow: KeySetupFlow
    var body: some View {
        Color.clear.sheet(isPresented: $flow.showGuide) { GoogleKeyGuide(flow: flow) }
    }
}

// MARK: - Status

/// Where the key setup stands, under the button (Voice page) and on the Account card.
struct KeySetupStatus: View {
    @ObservedObject var flow: KeySetupFlow

    var body: some View {
        switch flow.stage {
        case .idle:
            EmptyView()
        case .working(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.system(size: 12))
            }
            .foregroundStyle(Palette.cream)
        case .done:
            Note(text: "Voice typing is set up. Your key is saved in this Mac's Keychain.")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Note(text: "Couldn't set up the key automatically: \(message)", isError: true)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", style: .outline, action: flow.begin)
            }
        case .missingPermission:
            InfoPanel(icon: "checkmark.square", title: "The Google Cloud box wasn't ticked",
                      detail: "MicFlow can't create your key without it. Click Try again, and on Google's screen tick the box shown here, then click Continue.") {
                GuideImage(name: "Guide-Tick", maxHeight: 200)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", style: .ink, action: flow.continueToGoogle)
            }
        case .needsTerms:
            TermsPanel(flow: flow)
        case .freePlanOff:
            InfoPanel(icon: "exclamationmark.triangle", title: "Google turned off the free plan for this Google account",
                      detail: "MicFlow made the key, but Google doesn't let this account use it for free: every request is refused until billing is added. This is Google's decision for the whole account (many new accounts see it right now), so a new key in the same account won't help.") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What you can do").font(.system(size: 12, weight: .bold))
                    Text("• Set it up again and pick a different Google account on Google's screen.")
                    Text("• Or switch to Model 2: it needs no key at all.")
                    Text("• Or add billing to that Google account (paid).")
                }
                .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.75))
                HStack(spacing: 8) {
                    PillButton(title: "Use another Google account", systemImage: "person.2", style: .ink, action: flow.continueToGoogle)
                    PillButton(title: "Switch to Model 2", systemImage: "waveform", style: .cream, action: flow.useModel2)
                }
            }
        }
    }
}

private struct TermsPanel: View {
    @ObservedObject var flow: KeySetupFlow

    /// The usual order: the Google APIs terms (accounts new to Google Cloud), then the model's own.
    private enum Page { case apis, model, cloud }
    private var current: Page {
        switch flow.termsID {
        case "universal": return .apis
        case "cloud": return .cloud
        default: return .model
        }
    }
    /// Which page this is out of how many, as far as MicFlow can tell.
    private var number: Int { current == .model ? 2 : 1 }
    private var total: Int { current == .cloud ? 1 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if flow.justAccepted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mintText)
                    Text("Page 1 accepted. MicFlow opened page 2 for you: it looks almost the same, but it's a different page. Click Accept there too.")
                        .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            InfoPanel(icon: "doc.text.magnifyingglass",
                      title: total > 1 ? "Accept Google's terms: page \(number) of \(total)" : "Accept Google Cloud's terms",
                      detail: "Google needs your Google account to accept its terms once before it makes a key. Click Accept on each page; MicFlow notices by itself and moves on.") {
                if total > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        TermsRow(number: 1, title: "Google APIs Terms of Service", address: "…/terms/universal",
                                 state: current == .apis ? .now : .done(flow.acceptedTerms > 0 ? "Accepted" : "Already accepted"))
                        TermsRow(number: 2, title: "The voice model's terms", address: "…/terms/generative-language-api",
                                 state: current == .model ? .now : .next)
                    }
                    Text("The two pages look almost the same. The page's address shows which one you're on.")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                GuideImage(name: "Guide-Accept", maxHeight: 150)
                HStack(spacing: 10) {
                    PillButton(title: total > 1 ? "Open page \(number)" : "Open the terms page", systemImage: "arrow.up.right",
                               style: .ink, action: flow.openTerms)
                    if flow.isWatching {
                        ProgressView().controlSize(.small)
                        Text(flow.isChecking ? "Checking…" : "Checking automatically").font(.system(size: 11))
                            .foregroundStyle(Palette.ink.opacity(0.6))
                    } else {
                        PillButton(title: flow.hasValidToken ? "Check again" : "Sign in again", systemImage: "arrow.clockwise",
                                   style: .cream, action: flow.checkNow)
                    }
                }
                if let email = flow.email {
                    Text("The page opens in your Google account **\(email)**.").font(.system(size: 12))
                }
                Divider().padding(.vertical, 2)
                Text("Does it say \"already been accepted\" but MicFlow still waits?").font(.system(size: 12, weight: .bold))
                Text("Then the page opened in a different Google account. Click your picture at the top right of the page, switch to \(flow.email ?? "the account you signed in with"), and click Accept there.")
                    .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                GuideImage(name: "Guide-OtherAccount", maxHeight: 90)
            }
        }
    }
}

/// One terms page in the list: done, the one to accept now, or next.
private struct TermsRow: View {
    enum State { case done(String), now, next }
    let number: Int
    let title: String
    let address: String
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark").foregroundStyle(Palette.white)
                default: Text("\(number)").foregroundStyle(isNow ? Palette.white : Palette.ink.opacity(0.5))
                }
            }
            .font(.system(size: 11, weight: .heavy))
            .frame(width: 22, height: 22)
            .background(background, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: isNow ? .bold : .medium))
                Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            }
            Spacer()
            Text(label).font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(isNow ? Palette.white : Palette.ink.opacity(0.6))
                .background(isNow ? Palette.orange : Color.black.opacity(0.06), in: Capsule())
        }
        .padding(8)
        .background(isNow ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isNow ? Palette.orange : .clear, lineWidth: 1.5))
        .opacity(isNext ? 0.6 : 1)
    }

    private var isNow: Bool { if case .now = state { return true } else { return false } }
    private var isNext: Bool { if case .next = state { return true } else { return false } }
    private var background: Color {
        switch state {
        case .done: return Palette.mintText
        case .now: return Palette.orange
        case .next: return Color.black.opacity(0.08)
        }
    }
    private var label: String {
        switch state {
        case .done(let text): return text
        case .now: return "Accept now"
        case .next: return "Next, if Google asks"
        }
    }
}

/// A light, informative card (not an error) with a picture and actions.
struct InfoPanel<Content: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 30).background(Palette.yellow, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .bold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .foregroundStyle(Palette.ink)
        .padding(14)
        .background(Palette.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
