import AppKit
import Security
import UserNotifications

/// Looks for a newer MicFlow in the public repository's releases, tells you with a notification,
/// and installs it with one click: it downloads the disk image, checks that the new app is signed
/// by the same certificate as this one (so macOS keeps its Accessibility, microphone and Keychain
/// permissions), swaps it in and reopens. Settings live outside the app, so they stay as they are.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(version: String, notes: String), installing(String), failed(String)
    }

    @Published private(set) var state = State.idle
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var downloadURL: URL?
    /// Whether a new version may install by itself right now (the CMS says so for this release,
    /// and you're not in the middle of dictating or recording).
    var autoInstallAllowed: () -> Bool = { false }
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private static let latest = URL(string: "https://api.github.com/repos/\(SiteContentStore.repository)/releases/latest")!
    private static let notifiedKey = "updateNotifiedVersion"

    /// The admin build is made on its own Mac and never replaces itself with the public download.
    static var isEnabled: Bool {
        #if ADMIN
        return false
        #else
        return true
        #endif
    }

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        check(quietly: true)
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(quietly: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(quietly: Bool = false) {
        guard Self.isEnabled else { return }
        if case .installing = state { return }
        if !quietly { state = .checking }
        Task {
            do {
                var request = URLRequest(url: Self.latest)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if !quietly { state = .failed("Couldn't check for updates. Try again later.") }
                    return
                }
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let assets = json["assets"] as? [[String: Any]] ?? []
                let dmg = assets.lazy.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }
                guard Self.isNewer(version, than: currentVersion), let dmg, let url = URL(string: dmg) else {
                    if case .available = state { return }
                    state = quietly ? .idle : .upToDate
                    return
                }
                downloadURL = url
                state = .available(version: version, notes: Self.summary(json["body"] as? String ?? ""))
                if autoInstallAllowed() {
                    install()
                } else {
                    notify(version)
                }
            } catch {
                if !quietly { state = .failed("Couldn't check for updates: you may be offline.") }
            }
        }
    }

    /// The release notes' list of changes as plain text: no headings, pictures or Markdown marks.
    static func summary(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        let text = bullets.prefix(6).map { line -> String in
            var plain = String(line.dropFirst(2))
            for mark in ["**", "__", "`"] { plain = plain.replacingOccurrences(of: mark, with: "") }
            plain = plain.replacingOccurrences(of: "*", with: "")
            return "• " + plain
        }
        return text.joined(separator: "\n")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Once per new version.
    private func notify(_ version: String) {
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedKey)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MicFlow \(version) is ready"
            content.body = "Open MicFlow → Settings and click Update. Your settings and permissions stay as they are."
            center.add(UNNotificationRequest(identifier: "micflow-update-\(version)", content: content, trigger: nil))
        }
    }

    // MARK: Installing

    func install() {
        guard Self.isEnabled, let downloadURL, case .available(let version, _) = state else { return }
        state = .installing("Downloading MicFlow \(version)…")
        Task {
            do {
                try await installNow(from: downloadURL)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func installNow(from url: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MicFlow-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download didn't work. Try again later.") }
        let dmg = work.appendingPathComponent("MicFlow.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        state = .installing("Installing…")
        let mount = work.appendingPathComponent("mount")
        try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        // Usually where MicFlow is now; but a copy macOS runs from a read-only temporary place
        // (opened straight from Downloads or the disk image) updates into Applications instead.
        let current = InstallLocation.target()
        let staged = current.deletingLastPathComponent().appendingPathComponent(".MicFlow-update.app")
        do {
            let newApp = mount.appendingPathComponent("MicFlow.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw Failure("The download has no MicFlow app in it.") }
            guard Self.isSignedLikeThisApp(newApp) else {
                throw Failure("The new version isn't signed like this one, so it wasn't installed. Download it from GitHub instead.")
            }
            try? FileManager.default.removeItem(at: staged)
            try await Self.run("/usr/bin/ditto", [newApp.path, staged.path])
            // Not quarantined, so it opens from Applications rather than another temporary copy.
            _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        } catch {
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            if (error as? Failure) == nil, !FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) {
                throw Failure("MicFlow can't write to \(current.deletingLastPathComponent().path). Move MicFlow to Applications and try again.")
            }
            throw error
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        // Once MicFlow has quit: swap the apps and open the new one.
        let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "$1" && /bin/mv "$2" "$1" && /usr/bin/open "$1"
            /bin/rm -rf "$3"
            """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "swap", current.path, staged.path, work.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// Whether `app` meets this app's own code requirement: same identifier, same certificate.
    private static func isSignedLikeThisApp(_ app: URL) -> Bool {
        var selfCode: SecCode?
        var staticSelf: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess, let staticSelf,
              SecCodeCopyDesignatedRequirement(staticSelf, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        return SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output.prefix(200))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Where MicFlow lives, and moving it to Applications when it isn't in a proper place.
@MainActor
enum InstallLocation {
    /// macOS runs a quarantined app opened straight from Downloads (or a disk image) from a random,
    /// read-only folder ("App Translocation"), so nothing can be written next to it.
    static var isTemporaryCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// Where the app should be: its own folder if that's a normal, writable place; otherwise
    /// Applications (or the user's own Applications folder if the shared one isn't writable).
    static func target() -> URL {
        let running = URL(fileURLWithPath: Bundle.main.bundlePath)
        if !isTemporaryCopy, FileManager.default.isWritableFile(atPath: running.deletingLastPathComponent().path) {
            return running
        }
        let shared = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: shared.path) { return shared.appendingPathComponent("MicFlow.app") }
        let own = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own.appendingPathComponent("MicFlow.app")
    }

    /// Once, when MicFlow was opened from Downloads or the disk image: offers to move it to
    /// Applications, so updates and Open at login work. Settings and permissions stay the same.
    static func offerMoveIfNeeded() {
        guard isTemporaryCopy, !UserDefaults.standard.bool(forKey: "declinedMoveToApplications") else { return }
        let target = target()
        let alert = NSAlert()
        alert.messageText = "Move MicFlow to your Applications folder?"
        alert.informativeText = "MicFlow is running from Downloads or its disk image, so it can't update itself. Moving it fixes that. Your settings stay as they are."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
            return
        }
        let running = Bundle.main.bundlePath
        let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "$2.moving" && /usr/bin/ditto "$1" "$2.moving" && /usr/bin/xattr -dr com.apple.quarantine "$2.moving"
            /bin/rm -rf "$2" && /bin/mv "$2.moving" "$2" && /usr/bin/open "$2"
            """
        let move = Process()
        move.executableURL = URL(fileURLWithPath: "/bin/sh")
        move.arguments = ["-c", script, "move", running, target.path]
        do {
            try move.run()
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
