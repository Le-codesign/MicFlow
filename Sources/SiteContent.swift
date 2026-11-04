import AppKit
import Foundation

/// The About page and the posts in Settings. They're published as `content/site.json` (plus images
/// and PDFs in `content/media/`) in the public MicFlow repository, so every copy of MicFlow shows
/// the latest. The last copy fetched is kept for when the Mac is offline, and the app ships with the
/// About page built in.
struct SiteContent: Codable, Equatable {
    var about: About
    var posts: [Post]
    /// What users see when a new version is out, and whether it installs by itself.
    var update: UpdateNotice?
    /// A pop-up that stops the app until its condition is met (or you turn it off).
    var block: Blocker?

    struct UpdateNotice: Codable, Equatable {
        var title: String
        var subtitle: String
        /// Installs new versions without asking (set per release).
        var autoUpdate: Bool
        /// Versions older than this show the stronger "please update" notice.
        var minimumVersion: String?
        var outdatedTitle: String?
        var outdatedSubtitle: String?

        static let standard = UpdateNotice(title: "A new version of MicFlow is ready",
                                           subtitle: "Update to get the latest features and fixes. Your settings stay as they are.",
                                           autoUpdate: false, minimumVersion: nil,
                                           outdatedTitle: "Your MicFlow is out of date",
                                           outdatedSubtitle: "This version is too old to keep working well. Please update now.")
    }

    struct Blocker: Codable, Equatable {
        enum Condition: String, Codable, CaseIterable {
            /// Shown to everyone until you turn it off.
            case always
            /// Goes away once the user is on `minimumVersion` or newer.
            case update
            /// Goes away once the user signs in.
            case signIn
        }

        var enabled: Bool
        var title: String
        var message: String
        var condition: Condition
        var minimumVersion: String?
        /// A button, e.g. "Pay now" with its link.
        var buttonTitle: String?
        var buttonLink: String?

        static let empty = Blocker(enabled: false, title: "MicFlow is paused", message: "", condition: .always,
                                   minimumVersion: nil, buttonTitle: nil, buttonLink: nil)
    }

    struct About: Codable, Equatable {
        var name: String
        var role: String
        var bio: String
        /// A file in content/media, or nil for the photo built into the app.
        var photo: String?
        var linkedin: String
        var facebook: String
        /// Digits with the country code, e.g. 8801779053845.
        var whatsapp: String
    }

    struct Post: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        /// Plain text; web addresses in it become links.
        var body: String
        var image: String?
        var pdf: String?
        var date: Date
    }

    static let builtIn = SiteContent(
        about: About(
            name: "Abdullah Al Mamun",
            role: "Senior UX Designer at Musemind",
            bio: """
                Hi, I'm Abdullah. I design products from brief to launch. I'm a Senior UX Designer at Musemind, \
                and before that I led the UX team at Ostad, where the products I designed reached about \
                200,000 users. I've also built SaaS products on my own, like Mocku, an AI mock interview app.

                I made MicFlow for my own work and share it free with friends, family and anyone who finds it useful.

                I'm open to feature requests. Tell me what would make MicFlow better for you.
                """,
            photo: nil,
            linkedin: "https://www.linkedin.com/in/abdullahell/",
            facebook: "https://www.facebook.com/eabdullahel",
            whatsapp: "8801779053845"),
        posts: [], update: nil, block: nil)
}

@MainActor
final class SiteContentStore: ObservableObject {
    nonisolated static let repository = "abdulllahel/MicFlow"
    nonisolated static let branch = "main"
    nonisolated static let folder = "content"
    nonisolated static let rawBase = URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/\(folder)/")!

    @Published private(set) var content: SiteContent
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let cacheFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cacheFile = support.appendingPathComponent("site.json")
        content = (try? Data(contentsOf: cacheFile)).flatMap(Self.decode) ?? .builtIn
    }

    nonisolated static func decode(_ data: Data) -> SiteContent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SiteContent.self, from: data)
    }

    nonisolated static func encode(_ content: SiteContent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(content)
    }

    /// The address of a file in content/media.
    nonisolated static func mediaURL(_ name: String) -> URL { rawBase.appendingPathComponent("media").appendingPathComponent(name) }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            // The time in the address skips GitHub's cache, so a new post shows up at once.
            var components = URLComponents(url: Self.rawBase.appendingPathComponent("site.json"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            var request = URLRequest(url: components.url!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Nothing published yet: keep what's built in.
                if status == 404 { lastError = nil; return }
                guard status == 200, let fetched = Self.decode(data) else {
                    lastError = "Couldn't load the latest posts."
                    return
                }
                lastError = nil
                apply(fetched)
            } catch {
                lastError = "You're offline, so these may not be the latest posts."
            }
        }
    }

    /// Shows `content` and keeps it for next time.
    func apply(_ content: SiteContent) {
        if self.content != content { self.content = content }
        if let data = try? Self.encode(content) { try? data.write(to: cacheFile, options: .atomic) }
    }
}
