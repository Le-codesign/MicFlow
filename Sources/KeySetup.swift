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

    /// Set by the app.
    var signIn: () -> Void = {}
    var save: (String) async -> String? = { _ in "Not ready" }
    var afterSave: () -> Void = {}
    var fallbackEmail: () -> String? = { nil }
    var hasKey: () -> Bool = { false }

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
        case "terms2": email = "someone@gmail.com"; termsID = "generative-language-api"; acceptedTerms = 1; stage = .needsTerms
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
                stage = .failed("The new key didn't work yet (\(problem)). Try again in a minute.")
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
            if stage == .needsTerms, let previous = termsID, previous != id { acceptedTerms += 1 }
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
            Note(text: "Voice typing is set up. Your key is saved in your Keychain and your account.")
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
        }
    }
}

private struct TermsPanel: View {
    @ObservedObject var flow: KeySetupFlow

    /// What Google calls the terms it's asking for.
    private var termsName: String {
        switch flow.termsID {
        case "universal": return "the Google APIs Terms of Service"
        case "cloud": return "the Google Cloud Terms of Service"
        default: return "the terms for the voice model's API"
        }
    }

    var body: some View {
        InfoPanel(icon: "doc.text.magnifyingglass",
                  title: flow.acceptedTerms > 0 ? "Done. Google needs one more page accepted" : "One more click: accept the terms",
                  detail: (flow.acceptedTerms > 0 ? "Thanks, that one worked. " : "")
                    + "Google needs your account to accept \(termsName) once. Open the page, click Accept, and come back. MicFlow notices by itself.") {
            GuideImage(name: "Guide-Accept", maxHeight: 150)
            HStack(spacing: 10) {
                PillButton(title: "Open the terms page", systemImage: "arrow.up.right", style: .ink, action: flow.openTerms)
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
