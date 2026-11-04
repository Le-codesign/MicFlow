import Foundation

/// Uploads screenshots to ImgBB with your own free API key and returns a link. Images there are
/// unlisted: only someone with the link can see one; nothing lists your uploads. The key is kept
/// in the Keychain.
@MainActor
final class ImageHost: ObservableObject {
    enum LinkStyle: String, CaseIterable, Identifiable {
        case link, markdown
        var id: String { rawValue }
        var title: String { self == .link ? "Link" : "Markdown image" }
    }

    struct Upload {
        /// What to paste: the link, or a Markdown image.
        let text: String
        let url: URL
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let keyPage = URL(string: "https://api.imgbb.com/")!
    /// ImgBB takes images up to 32 MB.
    private static let maxUpload = 32 * 1024 * 1024
    private static let secret = KeychainSecret(service: "local.micboost.imgbb-key")

    @Published private(set) var hasKey: Bool
    @Published var linkStyle: LinkStyle {
        didSet { UserDefaults.standard.set(linkStyle.rawValue, forKey: "imageHostLinkStyle") }
    }
    private var cachedKey: String?

    init() {
        hasKey = Self.secret.exists()
        linkStyle = LinkStyle(rawValue: UserDefaults.standard.string(forKey: "imageHostLinkStyle") ?? "") ?? .link
    }

    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Self.secret.save(key) else { return }
        cachedKey = key
        hasKey = true
    }

    func removeKey() {
        Self.secret.delete()
        cachedKey = nil
        hasKey = false
    }

    func upload(_ file: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> Upload {
        guard ["png", "jpg", "jpeg", "gif", "webp"].contains(file.pathExtension.lowercased()) else {
            throw Failure("Only pictures can be uploaded for a link. Videos stay in your captures folder.")
        }
        guard let key = cachedKey ?? Self.secret.load() else {
            hasKey = false
            throw Failure("Add your free ImgBB key first: MicFlow › Capture › Share links.")
        }
        cachedKey = key
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maxUpload else { throw Failure("That picture is over 32 MB, too big to upload.") }
        progress(0.1)

        var components = URLComponents(string: "https://api.imgbb.com/1/upload")!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let boundary = "MicFlow-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("image", data.base64EncodedString())
        field("name", file.deletingPathExtension().lastPathComponent)
        body.append(Data("--\(boundary)--\r\n".utf8))

        let (answer, response) = try await URLSession.shared.upload(for: request, from: body)
        progress(1)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        guard status == 200, let info = json?["data"] as? [String: Any],
              let link = info["url"] as? String, let url = URL(string: link) else {
            let reason = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            if status == 400 || status == 403 { throw Failure("ImgBB didn't accept the key: \(reason)") }
            throw Failure("The upload didn't work: \(reason)")
        }
        let text = linkStyle == .markdown ? "![\(file.deletingPathExtension().lastPathComponent)](\(link))" : link
        return Upload(text: text, url: url)
    }
}
