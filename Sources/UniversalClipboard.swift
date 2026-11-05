import AppKit
import CryptoKit
import Foundation

/// Universal Clipboard: what you copy (text or an image) appears on your other MicFlow devices.
/// Items are encrypted on this Mac with a key made from the pairing code, which never leaves your
/// devices, so the server (and anyone running it) can't read them. The server only holds an item
/// while it's being delivered; anything older than a few minutes is deleted.
@MainActor
final class UniversalClipboard: ObservableObject {
    static let maxImageBytes = 5_000_000
    private static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private let codeSecret = KeychainSecret(service: "local.micboost.clipboard-code")

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "universalClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "universalClipboard"); restart() }
    }
    @Published private(set) var code: String?
    @Published private(set) var status = ""

    private let account: Account
    private let deviceID: String
    private var lastChange = NSPasteboard.general.changeCount
    private var poll: Timer?
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var lastSeen = ISO8601DateFormatter.withFraction.string(from: Date())

    init(account: Account) {
        self.account = account
        if let id = UserDefaults.standard.string(forKey: "clipboardDeviceID") { deviceID = id }
        else { deviceID = UUID().uuidString; UserDefaults.standard.set(deviceID, forKey: "clipboardDeviceID") }
    }

    // MARK: Pairing code

    /// Makes this Mac's code the first time it's needed. Another device enters it to join.
    func start() {
        Task {
            let saved = await Task.detached { [codeSecret] in codeSecret.load() }.value
            if let saved, !saved.isEmpty { code = saved } else { setCode(Self.newCode()) }
            restart()
        }
    }

    static func newCode() -> String {
        let chars = (0..<16).map { _ in codeAlphabet[Int.random(in: 0..<codeAlphabet.count)] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Uses the code from another device; returns false when it isn't a valid code.
    @discardableResult func useCode(_ text: String) -> Bool {
        let clean = Self.normalize(text)
        guard clean.count == 16, clean.allSatisfy({ Self.codeAlphabet.contains($0) }) else { return false }
        let chars = Array(clean)
        setCode(stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-"))
        restart()
        return true
    }

    private func setCode(_ value: String) { code = value; codeSecret.save(value) }

    private static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func key(user: String) -> SymmetricKey? {
        guard let code else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(Self.normalize(code).utf8)),
                                      salt: Data(user.utf8), info: Data("MicFlow clipboard v1".utf8), outputByteCount: 32)
    }

    // MARK: Running

    func restart() {
        poll?.invalidate(); poll = nil
        socketTask?.cancel(); socket?.cancel(); socket = nil
        guard enabled, code != nil else { status = enabled ? "" : "Off"; return }
        lastChange = NSPasteboard.general.changeCount
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        socketTask = Task { await listen() }
    }

    private func checkPasteboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        guard account.isSignedIn else { return }
        if let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first,
           board.string(forType: .string) == nil, let data = Self.imageData(image) {
            Task { await send(kind: "image", data) }
        } else if let text = board.string(forType: .string), !text.isEmpty {
            Task { await send(kind: "text", Data(text.utf8)) }
        }
    }

    /// PNG when it fits, else JPEG made smaller until it's under the limit.
    private static func imageData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, var rep = NSBitmapImageRep(data: tiff) else { return nil }
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxImageBytes { return png }
        for scale in [1.0, 0.75, 0.5, 0.35, 0.25] {
            if scale < 1, let cg = rep.cgImage {
                let size = NSSize(width: Double(cg.width) * scale, height: Double(cg.height) * scale)
                let small = NSImage(size: size)
                small.lockFocus()
                NSImage(cgImage: cg, size: .zero).draw(in: NSRect(origin: .zero, size: size))
                small.unlockFocus()
                guard let t = small.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { continue }
                rep = r
            }
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]), jpeg.count <= maxImageBytes { return jpeg }
        }
        return nil
    }

    private func send(kind: String, _ plain: Data) async {
        guard let user = account.user?.id, let key = key(user: user),
              let box = try? AES.GCM.seal(plain, using: key), let sealed = box.combined,
              let token = try? await account.token() else { return }
        let old = ISO8601DateFormatter.withFraction.string(from: Date().addingTimeInterval(-300))
        _ = try? await Backend.request("DELETE", "/rest/v1/clipboard_items", query: [URLQueryItem(name: "created_at", value: "lt.\(old)")], token: token)
        do {
            _ = try await Backend.request("POST", "/rest/v1/clipboard_items",
                                          json: ["device": deviceID, "device_name": Host.current().localizedName ?? "Mac",
                                                 "kind": kind, "data": sealed.base64EncodedString()], token: token)
            status = "Sent to your devices"
        } catch { status = "Couldn't send: \(error.localizedDescription)" }
    }

    // MARK: Receiving (Supabase Realtime)

    private func listen() async {
        while !Task.isCancelled {
            if account.isSignedIn, let token = try? await account.token(), let user = account.user?.id {
                await fetchNew(token: token, user: user)
                await connect(token: token, user: user)
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func connect(token: String, user: String) async {
        let host = BackendConfig.url.replacingOccurrences(of: "https://", with: "wss://")
        guard let url = URL(string: "\(host)/realtime/v1/websocket?apikey=\(BackendConfig.publishableKey)&vsn=1.0.0") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        let topic = "realtime:clipboard-\(user)"
        func push(_ event: String, _ payload: [String: Any], topic: String = topic) async {
            guard let data = try? JSONSerialization.data(withJSONObject: ["topic": topic, "event": event, "payload": payload, "ref": UUID().uuidString]),
                  let text = String(data: data, encoding: .utf8) else { return }
            try? await ws.send(.string(text))
        }
        await push("phx_join", ["config": ["postgres_changes": [["event": "INSERT", "schema": "public", "table": "clipboard_items",
                                                                 "filter": "user_id=eq.\(user)"]]], "access_token": token])
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                await push("heartbeat", [:], topic: "phoenix")
                if let fresh = try? await account.token() { await push("access_token", ["access_token": fresh]) }
            }
        }
        defer { beat.cancel(); ws.cancel() }
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else { return }
            if case .string(let text) = message, text.contains("\"postgres_changes\""),
               let fresh = try? await account.token() {
                await fetchNew(token: fresh, user: user)
            }
        }
    }

    private func fetchNew(token: String, user: String) async {
        let query = [URLQueryItem(name: "select", value: "device_name,kind,data,created_at"),
                     URLQueryItem(name: "device", value: "neq.\(deviceID)"),
                     URLQueryItem(name: "created_at", value: "gt.\(lastSeen)"),
                     URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "1")]
        guard let data = try? await Backend.request("GET", "/rest/v1/clipboard_items", query: query, token: token),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let row = rows.first,
              let created = row["created_at"] as? String else { return }
        // The server's time has "+00:00", which a URL would read as a space: keep it as UTC with a Z,
        // a millisecond later so the same item isn't fetched again.
        if let date = ISO8601DateFormatter.withFraction.date(from: created.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression))
            ?? ISO8601DateFormatter().date(from: created) {
            lastSeen = ISO8601DateFormatter.withFraction.string(from: date.addingTimeInterval(0.001))
        }
        guard let key = key(user: user), let text = row["data"] as? String, let sealed = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key) else {
            status = "An item couldn't be opened: check both devices use the same code"
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        if row["kind"] as? String == "image", let image = NSImage(data: plain) { board.writeObjects([image]) }
        else { board.setString(String(decoding: plain, as: UTF8.self), forType: .string) }
        lastChange = board.changeCount
        let from = row["device_name"] as? String ?? "your other device"
        status = "Received from \(from)"
        MicFlowNotifier.shared.notifyClipboard(from: from)
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
