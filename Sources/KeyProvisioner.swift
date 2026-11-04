import Foundation

/// Makes a voice-typing API key in the user's own Google account, using the access Google gave
/// MicFlow at sign-in (the "cloud-platform" permission): it picks the user's existing AI project if
/// they have one, otherwise makes a "MicFlow" project, switches on the model's API there, creates a
/// key that only works with that API, and returns it. The key belongs to the user and uses their
/// own free quota.
enum KeyProvisioner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        /// Where the user can fix it (e.g. accept the Cloud terms), if anywhere.
        let fixURL: URL?
        /// The account still has to accept terms on `fixURL`; trying again afterwards works.
        var needsTerms = false
        /// The project that was being set up, so a retry goes straight back to it.
        var project: String?
        /// Which of Google's terms are missing (e.g. "universal" or "generative-language-api").
        var termsID: String?
        init(_ message: String, fix: URL? = nil, needsTerms: Bool = false, termsID: String? = nil) {
            errorDescription = message
            fixURL = fix
            self.needsTerms = needsTerms
            self.termsID = termsID
        }
    }

    /// What Google's sign-in token allows: whose account it is and which permissions were ticked.
    struct TokenInfo {
        var email: String?
        var scopes: Set<String> = []
        var expiresIn: TimeInterval?
    }

    /// Asks Google about the token (sent in the request body, never in the address).
    static func tokenInfo(_ token: String) async -> TokenInfo? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/tokeninfo")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "access_token", value: token)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let expires = (json["expires_in"] as? String).flatMap(Double.init) ?? (json["expires_in"] as? Double)
        return TokenInfo(email: json["email"] as? String,
                         scopes: Set(((json["scope"] as? String) ?? "").split(separator: " ").map(String.init)),
                         expiresIn: expires)
    }

    /// A Google page opened in the given account (when the browser is signed in to several).
    static func page(_ url: URL, as email: String?) -> URL {
        guard let email, !email.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "authuser", value: email)]
        return parts.url ?? url
    }

    /// The model's API, which every key MicFlow makes is restricted to.
    private static let service = "generativelanguage.googleapis.com"

    /// Google's page where an account accepts the model API's own terms (once).
    static let termsPage = terms("generative-language-api")

    /// The Cloud page for one set of Google's terms. Google can ask for more than one, one after
    /// another: "universal" (Google APIs terms, for accounts new to Google Cloud) and the model's own.
    static func terms(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return URL(string: "https://console.cloud.google.com/terms/\(safe.isEmpty ? "generative-language-api" : safe)")!
    }

    /// The terms Google names in its answer ("…?error_code=390003&tos_id=universal&services=…").
    private static func missingTerms(_ error: [String: Any]?) -> String? {
        for detail in (error?["details"] as? [[String: Any]]) ?? [] {
            for violation in (detail["violations"] as? [[String: Any]]) ?? [] {
                guard let subject = violation["subject"] as? String,
                      let items = URLComponents(string: "https://x/" + subject)?.queryItems,
                      let id = items.first(where: { $0.name == "tos_id" })?.value, !id.isEmpty else { continue }
                return id
            }
        }
        return nil
    }

    /// With `project` (from an earlier try that stopped at the terms), only that project is tried
    /// again: one or two requests instead of looking through every project.
    static func createKey(googleToken: String, project known: String? = nil,
                         progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        if let known {
            try await enable(project: known, token: googleToken)
            progress("Creating your key…")
            return try await makeKey(project: known, token: googleToken)
        }
        progress("Finding your project…")
        let projects = try await listProjects(token: googleToken)
        // A project where the API is already on needs no terms and no switching on.
        for project in projects where try await serviceIsEnabled(project: project, token: googleToken) {
            progress("Creating your key…")
            return try await makeKey(project: project, token: googleToken)
        }
        let project = try await reuseOrCreateProject(projects, token: googleToken, progress: progress)
        progress("Switching on voice typing for your project…")
        try await enable(project: project, token: googleToken)
        progress("Creating your key…")
        return try await makeKey(project: project, token: googleToken)
    }

    // MARK: Project

    /// The user's active projects, AI ones and MicFlow's first.
    private static func listProjects(token: String) async throws -> [String] {
        let list = try await call("GET", "https://cloudresourcemanager.googleapis.com/v1/projects?pageSize=200", token: token)
        let projects = ((list["projects"] as? [[String: Any]]) ?? []).filter { ($0["lifecycleState"] as? String) == "ACTIVE" }
        voiceLog.info("Key setup: found \(projects.count) projects")
        func rank(_ project: [String: Any]) -> Int {
            let id = project["projectId"] as? String ?? ""
            if id.hasPrefix("gen-lang-client-") { return 0 }
            if id.hasPrefix("micflow-") || (project["name"] as? String) == "MicFlow" { return 1 }
            return 2
        }
        return projects.sorted { rank($0) < rank($1) }.compactMap { $0["projectId"] as? String }.prefix(10).map { $0 }
    }

    private static func serviceIsEnabled(project: String, token: String) async throws -> Bool {
        guard let state = try? await call("GET", "https://serviceusage.googleapis.com/v1/projects/\(project)/services/\(service)",
                                          token: token) else { return false }
        return (state["state"] as? String) == "ENABLED"
    }

    /// An earlier MicFlow project if there is one (so retries don't pile up projects), else a new one.
    private static func reuseOrCreateProject(_ projects: [String], token: String,
                                             progress: @escaping @Sendable (String) -> Void) async throws -> String {
        if let earlier = projects.first(where: { $0.hasPrefix("micflow-") }) { return earlier }
        progress("Creating a project for MicFlow…")
        let id = "micflow-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10))
        let operation = try await call("POST", "https://cloudresourcemanager.googleapis.com/v3/projects", token: token,
                                       body: ["projectId": id, "displayName": "MicFlow"])
        try await wait(for: operation, base: "https://cloudresourcemanager.googleapis.com/v3/", token: token)
        return id
    }

    /// Switches the API on, remembering the project in a terms failure.
    private static func enable(project: String, token: String) async throws {
        do {
            try await enableService(project: project, token: token)
        } catch var failure as Failure where failure.needsTerms {
            failure.project = project
            throw failure
        }
    }

    private static func enableService(project: String, token: String) async throws {
        let operation = try await call("POST", "https://serviceusage.googleapis.com/v1/projects/\(project)/services/\(service):enable",
                                       token: token, body: [:])
        try await wait(for: operation, base: "https://serviceusage.googleapis.com/v1/", token: token)
    }

    private static func makeKey(project: String, token: String) async throws -> String {
        let base = "https://apikeys.googleapis.com/v2/"
        let operation = try await call("POST", base + "projects/\(project)/locations/global/keys", token: token, body: [
            "displayName": "MicFlow",
            "restrictions": ["apiTargets": [["service": service]]],
        ])
        let done = try await wait(for: operation, base: base, token: token)
        guard let name = (done["response"] as? [String: Any])?["name"] as? String else {
            throw Failure("The key was made but its name didn't come back. Try again.")
        }
        let key = try await call("GET", base + "\(name)/keyString", token: token)
        guard let value = key["keyString"] as? String, !value.isEmpty else { throw Failure("The new key couldn't be read. Try again.") }
        return value
    }

    // MARK: Requests

    /// Polls a long-running operation until it's done (up to about a minute).
    @discardableResult
    private static func wait(for operation: [String: Any], base: String, token: String) async throws -> [String: Any] {
        var current = operation
        for _ in 0..<60 {
            if current["done"] as? Bool == true {
                if let error = current["error"] as? [String: Any] {
                    throw Failure(ProviderName.hide(error["message"] as? String ?? "Setting up the key didn't work."))
                }
                return current
            }
            guard let name = current["name"] as? String else { return current }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            current = try await call("GET", base + name, token: token)
        }
        throw Failure("Setting up the key is taking too long. Try again in a minute.")
    }

    private static func call(_ method: String, _ url: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(status)"
            // The exact answer, for fixing setup problems (it never contains the key).
            let path = URL(string: url)?.path ?? url
            voiceLog.info("Key setup: \(method, privacy: .public) \(path, privacy: .public) -> HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(1500) ?? "", privacy: .public)")
            let reasons = ((error?["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            if reasons.contains("UREQ_TOS_NOT_ACCEPTED") || message.contains("generative-language-api") {
                let id = missingTerms(error) ?? "generative-language-api"
                throw Failure("One more click: accept Google's terms on Google's page.", fix: terms(id), needsTerms: true, termsID: id)
            }
            if message.lowercased().contains("terms of service"), path.contains("cloudresourcemanager") {
                throw Failure("One more click: accept Google Cloud's terms.", fix: URL(string: "https://console.cloud.google.com/"),
                              needsTerms: true)
            }
            if status == 403, message.lowercased().contains("has not been used") || message.lowercased().contains("disabled") {
                throw Failure("Automatic setup isn't switched on for MicFlow yet. Paste a key instead for now.")
            }
            throw Failure(ProviderName.hide(message))
        }
        return json
    }
}
