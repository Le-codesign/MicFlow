import AppKit
import SwiftUI
import WebKit

/// Settings: the app's general settings and updates, an About page, and the posts, each a tab.
struct SettingsPage: View {
    @ObservedObject var model: BoostModel
    let theme: HomeTheme
    @AppStorage("settingsTab") private var tab = Tab.general

    enum Tab: String, CaseIterable {
        case general = "General", requests = "Feature Requests", posts = "What's New", about = "About"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Pill(title: item.rawValue, selected: tab == item) { tab = item }
                }
                Spacer()
            }
            .padding(.leading, 4)
            switch tab {
            case .general: GeneralPage(model: model, updater: model.updater, theme: theme)
            case .about: AboutPage(store: model.siteContent, account: model.account, theme: theme)
            case .requests: FeatureRequestsPage(store: model.featureRequests, account: model.account, theme: theme)
            case .posts: PostsPage(store: model.siteContent, account: model.account, theme: theme)
            }
        }
        .onAppear { model.siteContent.refresh() }
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: BoostModel
    @ObservedObject var updater: Updater
    let theme: HomeTheme

    #if ADMIN
    @State private var editingControl = false
    #endif

    var body: some View {
        PageBody {
            HeroCard(kicker: "Settings", title: "MicFlow lives in your Dock and menu bar",
                     detail: "This window holds every setting and your voice typing stats. Close it any time: MicFlow keeps running, and the menu bar icon has the same settings in a small panel.",
                     systemImage: "gearshape.fill") {
                PillButton(title: "Quit MicFlow", systemImage: "power", style: .ink, action: model.quit)
            }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "arrow.down.circle.fill", title: "Updates",
                            subtitle: "You have MicFlow \(updater.currentVersion)") {
                    updateContent
                }
                FeatureCard(theme: theme, systemImage: "power", title: "Open at login", subtitle: "Start MicFlow when you log in",
                            isOn: $model.launchAtLogin) {
                    Note(text: "MicFlow opens with your settings as you left them.")
                }
            } right: {
                AccountCard(account: model.account, theme: theme)
                ClipboardCard(clipboard: model.clipboard, account: model.account, theme: theme)
                FeatureCard(theme: theme, systemImage: "lock.shield.fill", title: "Privacy", subtitle: "What stays on this Mac") {
                    Note(text: "Your dictation history, stats and captures stay on this Mac. Your API keys are kept in the Keychain; if you sign in, your preferences and API key are also saved to your account.")
                }
            }
        }
        #if ADMIN
        .sheet(isPresented: $editingControl) { ContentAdminView(store: model.siteContent, section: .control) }
        #endif
    }

    @ViewBuilder private var updateContent: some View {
        if !Updater.isEnabled {
            Note(text: "This is your admin build. It updates when you build it, not from the public download.")
            #if ADMIN
            if model.account.isAdmin {
                PillButton(title: "Edit update notice and pop-up", systemImage: "pencil", style: .cream) { editingControl = true }
            } else {
                Note(text: "Sign in with your admin Google account (Account card) to edit the update notice and pop-up.")
            }
            #endif
        } else {
            switch updater.state {
            case .available(let version, let notes):
                Text("MicFlow \(version) is ready").font(.system(size: 14, weight: .semibold))
                if !notes.isEmpty { Note(text: notes) }
                PillButton(title: "Update and restart", systemImage: "arrow.down.circle", style: .cream, action: updater.install)
                Note(text: "Your settings, API key and permissions stay as they are.")
            case .installing(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 13))
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 13))
                }
            case .upToDate:
                Note(text: "You have the latest version.")
                PillButton(title: "Check again", style: .outline) { updater.check() }
            case .failed(let message):
                Note(text: message, isError: true)
                PillButton(title: "Try again", style: .outline) { updater.check() }
            case .idle:
                Note(text: "MicFlow checks for new versions by itself and tells you when one is ready.")
                PillButton(title: "Check now", style: .outline) { updater.check() }
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var store: SiteContentStore
    @ObservedObject var account: Account
    let theme: HomeTheme
    @State private var copied = false
    #if ADMIN
    @State private var editing = false
    #endif

    private var about: SiteContent.About { store.content.about }

    var body: some View {
        PageBody {
            DarkCard(theme: theme) {
                HStack(alignment: .top, spacing: 22) {
                    ProfilePhoto(about: about)
                        .frame(width: 132, height: 132)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Palette.cream, lineWidth: 3))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Made by").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.cream)
                        Text(about.name).font(.display(34))
                        Text(about.role).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.greyOnDark)
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Open to feature requests")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.yellow, in: Capsule())
                    }
                    Spacer()
                    #if ADMIN
                    if account.isAdmin {
                        PillButton(title: "Edit", systemImage: "pencil", style: .cream) { editing = true }
                    }
                    #endif
                }
            }
            CardColumns {
                FeatureCard(theme: theme, systemImage: "person.fill", title: "About me", subtitle: "Why MicFlow exists") {
                    Text(about.bio)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } right: {
                FeatureCard(theme: theme, systemImage: "bubble.left.and.bubble.right.fill", title: "Get in touch",
                            subtitle: "Ideas, bugs or feature requests") {
                    contactRow("WhatsApp", detail: Self.formatted(about.whatsapp), systemImage: "phone.fill",
                               url: URL(string: "https://wa.me/\(about.whatsapp)"))
                    HStack(spacing: 8) {
                        PillButton(title: copied ? "Copied" : "Copy number", systemImage: copied ? "checkmark" : "doc.on.doc",
                                   style: .outline) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("+\(about.whatsapp)", forType: .string)
                            copied = true
                        }
                    }
                    contactRow("LinkedIn", detail: "Connect with me", systemImage: "person.crop.square.fill", url: URL(string: about.linkedin))
                    contactRow("Facebook", detail: "Message me", systemImage: "f.square.fill", url: URL(string: about.facebook))
                }
            }
        }
        #if ADMIN
        .sheet(isPresented: $editing) { ContentAdminView(store: store, section: .about) }
        #endif
    }

    private func contactRow(_ title: String, detail: String, systemImage: String, url: URL?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Palette.cream).frame(width: 30, height: 30)
                    .overlay(Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.pink))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.greyOnDark)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
            }
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url?.absoluteString ?? "")
    }

    /// 8801779053845 → +880 1779-053845
    static func formatted(_ digits: String) -> String {
        guard digits.hasPrefix("880"), digits.count == 13 else { return "+" + digits }
        let local = digits.dropFirst(3)
        return "+880 \(local.prefix(4))-\(local.dropFirst(4))"
    }
}

/// The published photo, or the one built into the app.
struct ProfilePhoto: View {
    let about: SiteContent.About
    private static let builtIn = Bundle.main.url(forResource: "Profile", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let photo = about.photo {
            AsyncImage(url: SiteContentStore.mediaURL(photo)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallback
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        if let image = Self.builtIn {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Circle().fill(Palette.cream)
        }
    }
}

// MARK: - Posts

/// The posts, in a small browser: links in them open right here, with back, forward and reload.
struct PostsPage: View {
    @ObservedObject var store: SiteContentStore
    @ObservedObject var account: Account
    let theme: HomeTheme
    @StateObject private var browser = Browser()
    #if ADMIN
    @State private var editing = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New").font(.display(26)).foregroundStyle(Palette.white)
                Text("New updates and tips from the creator of MicFlow are shared here.")
                    .font(.system(size: 13)).foregroundStyle(Palette.cream)
            }
            .padding(.leading, 4)
            browserPanel
        }
    }

    private var browserPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                toolbarButton("chevron.left", help: "Back", enabled: browser.canGoBack) { browser.view.goBack() }
                toolbarButton("chevron.right", help: "Forward", enabled: browser.canGoForward) { browser.view.goForward() }
                toolbarButton("arrow.clockwise", help: "Reload") {
                    if browser.isHome { store.refresh() } else { browser.view.reload() }
                }
                toolbarButton("house.fill", help: "All posts", enabled: !browser.isHome) { browser.showHome(store.content) }
                HStack(spacing: 6) {
                    Image(systemName: browser.isHome ? "newspaper.fill" : "globe").font(.system(size: 11))
                    Text(browser.isHome ? "What's New" : browser.address)
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if browser.isLoading || store.isLoading { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(hex: 0xF2F2F0), in: Capsule())
                toolbarButton("safari", help: "Open in your browser", enabled: !browser.isHome) {
                    if let url = browser.view.url { NSWorkspace.shared.open(url) }
                }
                #if ADMIN
                if account.isAdmin {
                    PillButton(title: "Edit posts", systemImage: "pencil", style: .ink) { editing = true }
                }
                #endif
            }
            .padding(10)
            Divider()
            BrowserView(browser: browser)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { browser.showHome(store.content) }
        .onChange(of: store.content) { content in if browser.isHome { browser.showHome(content) } }
        #if ADMIN
        .sheet(isPresented: $editing) { ContentAdminView(store: store, section: .posts) }
        #endif
    }

    private func toolbarButton(_ systemImage: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(enabled ? Palette.ink : Palette.greyOnLight.opacity(0.5))
                .background(Color(hex: 0xF2F2F0), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var address = ""
    /// The list of posts, which MicFlow draws itself, rather than a web page.
    @Published private(set) var isHome = true
    private static let homeURL = URL(string: "about:blank#posts")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
    }

    func showHome(_ content: SiteContent) {
        view.loadHTMLString(PostsHTML.page(content), baseURL: SiteContentStore.rawBase)
        isHome = true
    }

    private func update() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = view.isLoading
        let url = view.url
        isHome = url == nil || url?.absoluteString == SiteContentStore.rawBase.absoluteString
        address = url?.absoluteString ?? ""
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { update() }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { update() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { update() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { update() }
    }

    /// Links meant for a new window open here instead.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        }
        return nil
    }

    /// Only web pages, PDFs and images open in here; mail and WhatsApp links go to their apps.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased() ?? ""
            if ["http", "https", "about", "data"].contains(scheme) {
                if let host = url?.host, host == "wa.me" || host.hasSuffix("whatsapp.com") {
                    NSWorkspace.shared.open(url!)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            } else {
                if let url { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
    }
}

struct BrowserView: NSViewRepresentable {
    let browser: Browser
    func makeNSView(context: Context) -> WKWebView { browser.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The list of posts as a web page, newest first.
enum PostsHTML {
    static func page(_ content: SiteContent) -> String {
        let posts = content.posts.sorted { $0.date > $1.date }
        let items = posts.isEmpty
            ? "<div class=\"empty\"><h2>Nothing here yet</h2><p>New updates and tips about MicFlow will show up here.</p></div>"
            : posts.map(item).joined()
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: light; }
            body { margin: 0; padding: 28px; background: #fff; color: #141414;
                   font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
            main { max-width: 720px; margin: 0 auto; }
            article { background: #F2F2F0; border-radius: 22px; padding: 22px 24px; margin-bottom: 16px; }
            h2 { font-size: 22px; line-height: 1.25; margin: 0 0 4px; }
            time { color: #8A8A8A; font-size: 12px; }
            p { margin: 12px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
            img { display: block; width: 100%; border-radius: 14px; margin-top: 14px; }
            a { color: #F2621F; font-weight: 600; }
            .pdf { display: inline-block; margin-top: 14px; padding: 8px 16px; border-radius: 999px;
                   background: #141414; color: #FBEBC9; text-decoration: none; }
            .empty { text-align: center; padding: 80px 20px; color: #8A8A8A; }
            .empty h2 { color: #141414; }
            </style></head><body><main>\(items)</main></body></html>
            """
    }

    private static func item(_ post: SiteContent.Post) -> String {
        let date = post.date.formatted(date: .long, time: .omitted)
        var html = "<article><h2>\(escape(post.title))</h2><time>\(escape(date))</time>"
        if let image = post.image { html += "<img src=\"\(SiteContentStore.mediaURL(image).absoluteString)\" alt=\"\">" }
        if !post.body.isEmpty { html += "<p>\(linkify(escape(post.body)))</p>" }
        if let pdf = post.pdf { html += "<a class=\"pdf\" href=\"\(SiteContentStore.mediaURL(pdf).absoluteString)\">Open the PDF</a>" }
        return html + "</article>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Web addresses (already escaped) become links; a trailing full stop or bracket stays text.
    static func linkify(_ text: String) -> String {
        let pattern = #"(https?://|www\.)[^\s<]+[^\s<.,;:!?)\]'"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            result += text[last..<r.lowerBound]
            let shown = String(text[r])
            let href = shown.lowercased().hasPrefix("www.") ? "https://" + shown : shown
            result += "<a href=\"\(href)\">\(shown)</a>"
            last = r.upperBound
        }
        return result + text[last...]
    }
}

/// Universal Clipboard: on/off, this Mac's pairing code, and entering another device's code.
struct ClipboardCard: View {
    @ObservedObject var clipboard: UniversalClipboard
    @ObservedObject var account: Account
    let theme: HomeTheme
    @State private var entered = ""
    @State private var wrongCode = false

    var body: some View {
        FeatureCard(theme: theme, systemImage: "doc.on.clipboard.fill", title: "Universal Clipboard",
                    subtitle: "Copy here, paste on your phone", isOn: $clipboard.enabled) {
            if !account.isSignedIn {
                Note(text: "Sign in with Google to share your clipboard with MicFlow on your phone.")
            } else if let code = clipboard.code {
                Note(text: "Text and images you copy go to your other devices, end-to-end encrypted. To link a device, enter this code in its MicFlow:")
                Text(code).font(.system(size: 17, weight: .bold, design: .monospaced)).textSelection(.enabled)
                HStack {
                    TextField("Or enter the code from your phone", text: $entered).textFieldStyle(.roundedBorder)
                    PillButton(title: "Link", systemImage: "link") {
                        wrongCode = !clipboard.useCode(entered)
                        if !wrongCode { entered = "" }
                    }
                }
                if wrongCode { Note(text: "That isn't a valid code: it has 16 letters and numbers.", isError: true) }
                if !clipboard.status.isEmpty { Note(text: clipboard.status) }
            }
        }
    }
}
