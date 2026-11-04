import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// MicFlow's online part, on Supabase's free plan: optional Google sign-in, your preferences and API
/// key saved to your account, and feature requests with comments and votes. Fill in the two values
/// from your Supabase project (Project Settings › API); the publishable key is meant to be public.
/// See Backend/SETUP.md.
enum BackendConfig {
    static let url = "https://igieggvaaxcrbepvpxmi.supabase.co"
    static let publishableKey = "sb_publishable_ldSK8ZCk-4bo2crFSp2OQw__AnZ6SxZ"

    static var isConfigured: Bool { !url.isEmpty && !publishableKey.isEmpty }
    /// Where Google sends you back to MicFlow after signing in. Add it in Supabase › Authentication ›
    /// URL Configuration › Redirect URLs.
    static let callbackScheme = "micflow"
    static let callback = "micflow://auth-callback"
}

struct BackendError: LocalizedError {
    let errorDescription: String?
    let status: Int
    init(_ message: String, status: Int = 0) {
        errorDescription = message
        self.status = status
    }
}

/// Talks to Supabase's REST endpoints directly (no extra libraries).
enum Backend {
    /// Sends a request; `token` is the signed-in (or device) session, else the publishable key.
    static func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil,
                        data: Data? = nil, contentType: String? = nil, token: String?,
                        prefer: String? = nil) async throws -> Data {
        guard BackendConfig.isConfigured, var components = URLComponents(string: BackendConfig.url + path) else {
            throw BackendError("Accounts aren't set up in this version of MicFlow yet.")
        }
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(BackendConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token ?? BackendConfig.publishableKey)", forHTTPHeaderField: "Authorization")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let data {
            request.httpBody = data
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let reason = (json?["msg"] ?? json?["message"] ?? json?["error_description"] ?? json?["error"]) as? String
            throw BackendError(reason ?? "The server answered \(status).", status: status)
        }
        return body
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // Postgres sends microseconds (".123456"); the parser takes whole seconds reliably.
            let text = try decoder.singleValueContainer().decode(String.self)
                .replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }

    static func publicFileURL(_ path: String) -> URL? {
        URL(string: "\(BackendConfig.url)/storage/v1/object/public/\(path)")
    }
}

/// Your MicFlow account. Signing in is optional. Without it, MicFlow still makes an invisible
/// device account the first time you vote, so each Mac votes once per request.
@MainActor
final class Account: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct User: Codable, Equatable {
        var id: String
        var email: String?
        var name: String?
        var avatar: String?
        var isAnonymous: Bool
    }

    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var user: User
    }

    @Published private(set) var user: User?
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    var isConfigured: Bool { BackendConfig.isConfigured }
    /// True when the signed-in Google account is in the database's admins list. Editing What's New,
    /// About and the update notice needs this, even in the admin build, and deleting anyone's
    /// feature request too.
    @Published private(set) var isAdmin = false

    private func refreshAdmin() {
        guard isSignedIn else { isAdmin = false; return }
        Task {
            guard let token = try? await token(),
                  let data = try? await Backend.request("POST", "/rest/v1/rpc/is_admin", json: [:], token: token) else {
                isAdmin = false
                return
            }
            isAdmin = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
    }
    /// Signed in with Google (not just the device account).
    var isSignedIn: Bool { user.map { !$0.isAnonymous } ?? false }

    private var session: Session? {
        didSet {
            user = session?.user
            if session?.user.id != oldValue?.user.id { refreshAdmin() }
            let secret = KeychainSecret(service: "local.micboost.account-session")
            if let session, let data = try? JSONEncoder().encode(session) {
                secret.save(String(decoding: data, as: UTF8.self))
            } else {
                secret.delete()
            }
        }
    }
    private var webSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        // Only whether a session exists is checked now; it's read when first needed.
        if KeychainSecret(service: "local.micboost.account-session").exists() {
            Task { await loadSession() }
        }
    }

    private func loadSession() async {
        let raw = await Task.detached { KeychainSecret(service: "local.micboost.account-session").load() }.value
        guard session == nil, let raw, let saved = try? JSONDecoder().decode(Session.self, from: Data(raw.utf8)) else { return }
        session = saved
    }

    // MARK: Tokens

    /// A valid access token, refreshed when it's about to run out. With `orDevice`, makes the
    /// device account first if you're not signed in at all.
    func token(orDevice: Bool = false) async throws -> String? {
        if session == nil { await loadSession() }
        if session == nil, orDevice { try await signInAsDevice() }
        guard let current = session else { return nil }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        do {
            let data = try await Backend.request("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                                 json: ["refresh_token": current.refreshToken], token: nil)
            session = try Self.session(from: data)
            return session?.accessToken
        } catch let error as BackendError where error.status == 400 || error.status == 401 {
            session = nil
            throw BackendError("You were signed out. Please sign in again.")
        }
    }

    private func signInAsDevice() async throws {
        let data = try await Backend.request("POST", "/auth/v1/signup", json: ["data": [:]], token: nil)
        session = try Self.session(from: data)
    }

    private static func session(from data: Data) throws -> Session {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let userJSON = json["user"] as? [String: Any], let id = userJSON["id"] as? String else {
            throw BackendError("The sign-in answer was incomplete.")
        }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let meta = userJSON["user_metadata"] as? [String: Any] ?? [:]
        let user = User(id: id, email: userJSON["email"] as? String,
                        name: (meta["full_name"] ?? meta["name"]) as? String,
                        avatar: (meta["avatar_url"] ?? meta["picture"]) as? String,
                        isAnonymous: userJSON["is_anonymous"] as? Bool ?? false)
        return Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn), user: user)
    }

    // MARK: Google sign-in

    /// The Google permission that lets MicFlow make the user's API key in their own account.
    static let cloudScope = "https://www.googleapis.com/auth/cloud-platform"
    /// Whether sign-in should also make an API key (set by the app: when there's no key yet).
    var wantsKeySetup: () -> Bool = { false }
    /// Gets Google's access token when sign-in asked for the key permission (nil: none came back).
    var onGoogleToken: ((String?) -> Void)?
    /// Making the key: the guide, progress, the terms step.
    let keySetup = KeySetupFlow()

    /// Opens Google's sign-in in a secure browser sheet, then comes back to MicFlow (PKCE flow).
    /// With `setUpKey` (or when the app has no key yet), Google is also asked for permission to
    /// make a voice-typing key in the user's account.
    func signIn() { signIn(setUpKey: wantsKeySetup()) }

    func signIn(setUpKey: Bool) {
        guard isConfigured, !isWorking else { return }
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var components = URLComponents(string: BackendConfig.url + "/auth/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: BackendConfig.callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        if setUpKey {
            components.queryItems?.append(URLQueryItem(name: "scopes", value: Self.cloudScope))
            // Google's account list every time, so "Use another Google account" really can pick another one.
            components.queryItems?.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        isWorking = true
        message = nil
        let web = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: BackendConfig.callbackScheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isWorking = false; self.webSession = nil }
                guard let url, error == nil,
                      let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
                    self.message = "Sign-in didn't finish. Try again."
                    return
                }
                do {
                    let data = try await Backend.request("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "pkce")],
                                                         json: ["auth_code": code, "code_verifier": verifier], token: nil)
                    self.session = try Self.session(from: data)
                    self.onSignedIn?()
                    if setUpKey {
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let googleToken = (json?["provider_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        self.onGoogleToken?(googleToken)
                    }
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
        web.presentationContextProvider = self
        web.prefersEphemeralWebBrowserSession = false
        webSession = web
        web.start()
    }

    /// Called after a Google sign-in, to load and merge your saved preferences.
    var onSignedIn: (() -> Void)?

    func signOut() {
        let token = session?.accessToken
        session = nil
        if let token { Task { _ = try? await Backend.request("POST", "/auth/v1/logout", token: token) } }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow() }
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Preferences in your account

/// Your instructions, words, mix-ups and API key, saved to your account so they come back after a
/// reinstall or on another Mac. Only your own sign-in can read them back.
struct SavedPreferences: Codable {
    var instructions: String
    var instructions_enabled: Bool
    var my_words: [String]
    var mix_ups: [MixUp]
    var api_key: String?
}

@MainActor
enum PreferenceSync {
    static func load(_ account: Account) async throws -> SavedPreferences? {
        guard account.isSignedIn, let token = try await account.token(), let id = account.user?.id else { return nil }
        let data = try await Backend.request("GET", "/rest/v1/profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "select", value: "instructions,instructions_enabled,my_words,mix_ups,api_key"),
        ], token: token)
        return try JSONDecoder().decode([SavedPreferences].self, from: data).first
    }

    static func save(_ preferences: SavedPreferences, account: Account) async throws {
        guard account.isSignedIn, let token = try await account.token(), let user = account.user else { return }
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any] ?? [:]
        row["id"] = user.id
        row["email"] = user.email
        row["name"] = user.name
        row["updated_at"] = ISO8601DateFormatter().string(from: Date())
        // Clears a key an older version saved to the account: keys now stay in the Mac's Keychain only.
        row["api_key"] = NSNull()
        _ = try await Backend.request("POST", "/rest/v1/profiles", json: [row], token: token,
                                      prefer: "resolution=merge-duplicates,return=minimal")
    }
}
