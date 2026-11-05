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

    @Published private(set) var stage = Stage.idle {
        didSet {
            switch stage {
            case .failed, .freePlanOff, .missingPermission: hasFailed = true
            case .done: hasFailed = false
            default: break
            }
        }
    }
    /// Setting up with Google didn't work at least once: Home then also offers pasting a key.
    @Published private(set) var hasFailed = false
    /// Google's own words when it refused to make a key, shown small under the simple explanation.
    @Published private(set) var failureDetail: String?
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

    /// A step of the sign-in that isn't Google's (bringing back settings, restarting).
    func showStep(_ text: String) {
        stop()
        stage = .working(text)
    }

    /// The account already had a key (brought back from it): nothing to make.
    func finishedWithSavedKey() {
        stop()
        stage = .done
    }

    /// "I've accepted": check right now, in case the automatic check hasn't caught it yet.
    func confirmAccepted() {
        justAccepted = false
        checkNow()
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
        } catch is URLError {
            stage = .failed("MicFlow couldn't reach Google. Check your internet connection and try again.")
            stop()
            return false
        } catch {
            // Google refused to make a project or key for this account.
            failureDetail = error.localizedDescription
            stage = .freePlanOff
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

/// The pop-up before Google's sign-in: three short slides in MicFlow's colours, one thing to do on
/// each Google screen, then Google's own "Continue with Google" button.
struct GoogleKeyGuide: View {
    @ObservedObject var flow: KeySetupFlow
    @AppStorage(KeySetupFlow.skipGuideKey) private var dontShowAgain = false
    @State private var index = 0

    private struct Slide {
        let image: String
        let title: String
        let detail: String
    }

    private let slides = [
        Slide(image: "Guide-Advanced", title: "Click Advanced, then \"Go to … (unsafe)\"",
              detail: "Google shows this warning because its review of MicFlow isn't finished yet. MicFlow only uses the access to make your key."),
        Slide(image: "Guide-Tick", title: "Tick the Google Cloud box",
              detail: "This is the important one. Without the tick MicFlow can't make your key. Then click Continue."),
        Slide(image: "Guide-Accept", title: "Accept Google's terms",
              detail: "One or two pages, only once. MicFlow opens them in the right account and notices when you're done."),
    ]

    var body: some View {
        let slide = slides[index]
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Before you sign in: 3 quick things").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.cream)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(slides.indices, id: \.self) { dot in
                        Capsule().fill(dot == index ? Palette.yellow : Color.white.opacity(0.25))
                            .frame(width: dot == index ? 26 : 8, height: 8)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: index)
            }
            .padding(.horizontal, 26).padding(.top, 22)

            ZStack(alignment: .topLeading) {
                GuideImage(name: slide.image, maxHeight: 290)
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("\(index + 1)").font(.display(30)).foregroundStyle(Palette.white)
                    .frame(width: 58, height: 52)
                    .background(Palette.pink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.white, lineWidth: 3))
                    .rotationEffect(.degrees(-10))
                    .offset(x: -12, y: -14)
            }
            .padding(.horizontal, 26).padding(.top, 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(slide.title).font(.display(28)).foregroundStyle(Palette.white)
                Text(slide.detail).font(.system(size: 14)).foregroundStyle(Palette.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26).padding(.top, 18)
            .id(index)
            .transition(.opacity)

            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Toggle(isOn: $dontShowAgain) {
                    Text("Don't show this again").font(.system(size: 12)).foregroundStyle(Palette.white.opacity(0.85))
                }
                .toggleStyle(.checkbox)
                Spacer()
                PillButton(title: "Cancel", style: .outline) { flow.showGuide = false }
                    .keyboardShortcut(.cancelAction)
                if index > 0 {
                    PillButton(title: "Back", systemImage: "chevron.left", style: .outline) { withAnimation { index -= 1 } }
                }
                if index < slides.count - 1 {
                    PillButton(title: "Next", systemImage: "chevron.right", style: .cream) { withAnimation { index += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    GoogleSignInButton(title: "Continue with Google", size: .regular, action: flow.continueToGoogle)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
            .background(Color.black.opacity(0.18))
        }
        .frame(width: 600, height: 640)
        .background(HomeTheme.green.frame)
        .environment(\.colorScheme, .dark)
    }
}

/// Google's own light "Sign in with Google" button (from Google's branding guidelines): white,
/// a thin grey outline, the four-colour G and dark text, so people recognise it at once.
struct GoogleSignInButton: View {
    enum Size { case regular, large }
    var title = "Sign in with Google"
    var size = Size.large
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: size == .large ? 14 : 10) {
                if isWorking {
                    Spinner().frame(width: size == .large ? 26 : 18, height: size == .large ? 26 : 18)
                } else if let logo = Bundle.main.url(forResource: "GoogleG", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: logo).resizable().frame(width: size == .large ? 26 : 18, height: size == .large ? 26 : 18)
                }
                Text(isWorking ? "Waiting for Google…" : title)
                    .font(.system(size: size == .large ? 19 : 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1F1F1F))
            }
            .padding(.horizontal, size == .large ? 28 : 18)
            .frame(height: size == .large ? 60 : 40)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0x747775), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
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
            Note(text: "Voice typing is ready. Your key is saved in this Mac's Keychain and, locked, in your account, so it comes back on any Mac you sign in on.")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Note(text: "Couldn't set up the key automatically: \(message)", isError: true)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", style: .outline, action: flow.begin)
            }
        case .missingPermission:
            InfoPanel(icon: "checkmark.square", title: "The Google Cloud box wasn't ticked",
                      detail: "MicFlow needs that permission to make your key. Click Try again, tick the box shown here on Google's screen, then click Continue.") {
                GuideImage(name: "Guide-Tick", maxHeight: 200)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", style: .ink, action: flow.continueToGoogle)
            }
        case .needsTerms:
            TermsPanel(flow: flow)
        case .freePlanOff:
            InfoPanel(icon: "person.crop.circle.badge.exclamationmark", title: "This Google account can't get a voice key yet",
                      detail: "Google decides which accounts get the free key, partly from how the account has been used (Google's own note is below). It isn't something you did wrong.") {
                GuideImage(name: "Guide-GoogleNote", maxHeight: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What we found").font(.system(size: 12, weight: .bold))
                    Text("Some of our Google accounts that hadn't been used for a long time couldn't get a key. After we used them for a day (Gmail, YouTube, search), Google let them make one.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("What to do").font(.system(size: 12, weight: .bold)).padding(.top, 4)
                    Text("• Use this Google account as usual for a while, then try again in a few hours or tomorrow.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("• Or try now with a Google account you use every day.")
                    Text("• Or paste your own key (below), if you have one.")
                }
                .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.78))
                if let detail = flow.failureDetail {
                    Text("Google said: \(ProviderName.hide(detail))").font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                PillButton(title: "Try another Google account", systemImage: "person.2", style: .ink, action: flow.continueToGoogle)
            }
        }
    }
}

private struct TermsPanel: View {
    @ObservedObject var flow: KeySetupFlow

    private enum Current { case apis, model, cloud }
    private var current: Current {
        switch flow.termsID {
        case "universal": return .apis
        case "cloud": return .cloud
        default: return .model
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if flow.justAccepted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mintText)
                    Text("Step 2 is done. MicFlow opened step 3 for you: it looks almost the same, but it's a different page. Click Accept there too.")
                        .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            InfoPanel(icon: "doc.text.magnifyingglass", title: "Almost done: accept Google's terms",
                      detail: "Google asks every account to accept its terms once before it makes a key. Do the steps in order; MicFlow notices each one by itself.") {
                VStack(alignment: .leading, spacing: 0) {
                    TermsStep(number: 1, title: "Allow Google Cloud access", address: "The box you ticked on Google's screen",
                              state: .done("Done"), isLast: false, flow: flow, pageNumber: nil)
                    TermsStep(number: 2, title: current == .cloud ? "Google Cloud Terms of Service" : "Google APIs Terms of Service",
                              address: current == .cloud ? "console.cloud.google.com" : "…/terms/universal",
                              state: current == .model ? .done(flow.acceptedTerms > 0 ? "Accepted" : "Already accepted") : .now,
                              isLast: current == .cloud, flow: flow, pageNumber: 2)
                    if current != .cloud {
                        TermsStep(number: 3, title: "The voice model's terms", address: "…/terms/generative-language-api",
                                  state: current == .model ? .now : .next, isLast: true, flow: flow, pageNumber: 3)
                    }
                }
                Text("Steps 2 and 3 look almost the same. The page's address shows which one you're on.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if let email = flow.email {
                    Text("The pages open in your Google account **\(email)**.").font(.system(size: 12))
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

/// One step of the terms, joined to the next by a line that turns green once the step is done.
/// The step to do now has its own buttons and the checking status under it.
private struct TermsStep: View {
    enum State { case done(String), now, next }
    let number: Int
    let title: String
    let address: String
    let state: State
    let isLast: Bool
    @ObservedObject var flow: KeySetupFlow
    let pageNumber: Int?

    private var isDone: Bool { if case .done = state { return true } else { return false } }
    private var isNow: Bool { if case .now = state { return true } else { return false } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(isDone ? Palette.mintText : isNow ? Palette.orange : Color.black.opacity(0.08))
                    if isDone {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.white)
                    } else {
                        Text("\(number)").font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(isNow ? Palette.white : Palette.ink.opacity(0.45))
                    }
                }
                .frame(width: 26, height: 26)
                if !isLast {
                    Rectangle().fill(isDone ? Palette.mintText : Color.black.opacity(0.12))
                        .frame(width: 3).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: isNow ? .bold : .semibold))
                            .foregroundStyle(Palette.ink.opacity(isNow || isDone ? 1 : 0.5))
                        Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
                    }
                    Spacer()
                    if case .done(let label) = state {
                        Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.mintText)
                    } else if case .next = state {
                        Text("Next").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.4))
                    }
                }
                if isNow {
                    if number == 3 {
                        GuideImage(name: "Guide-Accept", maxHeight: 110)
                    } else {
                        Text("Open the page and click the blue Accept button.").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.75))
                    }
                    HStack(spacing: 8) {
                        PillButton(title: "Open step \(pageNumber ?? number)", systemImage: "arrow.up.right", style: .ink, action: flow.openTerms)
                        PillButton(title: "I've accepted", systemImage: "checkmark", style: .outlineOnLight, action: flow.confirmAccepted)
                    }
                    HStack(spacing: 8) {
                        if flow.isWatching || flow.isChecking {
                            Spinner()
                            Text(flow.isChecking ? "Checking with Google now…" : "Checking automatically every few seconds")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                        } else {
                            Image(systemName: "pause.circle.fill").foregroundStyle(Palette.ink.opacity(0.6))
                            Text(flow.hasValidToken ? "Automatic checking stopped. Click I've accepted after accepting."
                                 : "Google's access ran out. Click I've accepted to sign in again.")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.75))
                        }
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }
}

/// A dark, clearly visible loading ring (the system one is too faint on cream).
struct Spinner: View {
    @State private var turning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
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
