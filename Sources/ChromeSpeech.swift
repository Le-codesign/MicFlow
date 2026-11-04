import AppKit
import Network

/// Free speech recognition through Google Chrome's built-in recognizer (the Web Speech API, which
/// sends audio to Google's servers). Chrome listens in one language at a time: a second recognizer
/// can't run alongside, so the language is chosen when listening starts. MicFlow serves a small page on 127.0.0.1 that Chrome
/// keeps open in a background tab; the page gets "start"/"stop" over a server-sent event stream
/// and posts back what it heard. The port is fixed so Chrome remembers the microphone permission.
@MainActor
final class ChromeSpeechBridge {
    static let port: UInt16 = 47_811
    static let pageURL = URL(string: "http://127.0.0.1:\(port)/")!
    private static let chromeID = "com.google.Chrome"

    private var listener: NWListener?
    /// Open event streams to the page (normally one).
    private var streams: [NWConnection] = []
    private var pendingResult: CheckedContinuation<String?, Never>?
    private var earlyResult: String?
    private var pingTimer: Timer?
    private var openedPageAt: Date?

    var isConnected: Bool { !streams.isEmpty }
    var chromeInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeID) != nil }

    func start() {
        guard listener == nil else { return }
        guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        // Keeps the event stream alive through proxies and lets us notice closed tabs.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcast(nil) }
        }
        // The page reconnects by itself if Chrome still has it open; otherwise open it once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openPageIfNeeded() }
    }

    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        streams.forEach { $0.cancel() }
        streams = []
        listener?.cancel()
        listener = nil
        pendingResult?.resume(returning: nil)
        pendingResult = nil
    }

    /// Opens the page in Chrome without bringing Chrome to the front.
    func openPageIfNeeded() {
        guard listener != nil, !isConnected, chromeInstalled,
              openedPageAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeID) else { return }
        openedPageAt = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([Self.pageURL], withApplicationAt: chrome, configuration: configuration)
    }

    /// `language` is a BCP 47 code such as "bn-BD" or "en-US".
    func beginListening(language: String) {
        earlyResult = nil
        broadcast("start:" + language)
    }

    /// Stops listening and waits up to 5 s for what Chrome heard; nil if nothing came back.
    func finishListening() async -> String? {
        broadcast("stop")
        if let earlyResult {
            self.earlyResult = nil
            return earlyResult
        }
        return await withCheckedContinuation { continuation in
            pendingResult = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let pending = self.pendingResult else { return }
                self.pendingResult = nil
                pending.resume(returning: nil)
            }
        }
    }

    func cancelListening() {
        broadcast("stop")
        earlyResult = nil
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads until the headers (and any body named by Content-Length) have arrived.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if isComplete || error != nil || buffer.count > 1_000_000 { connection.cancel() } else {
                        self.receiveRequest(on: connection, buffer: buffer)
                    }
                    return
                }
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[headerEnd.upperBound...]
                if body.count < length, !isComplete, error == nil {
                    self.receiveRequest(on: connection, buffer: buffer)
                    return
                }
                let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
                self.handle(requestLine, body: Data(body.prefix(length)), on: connection)
            }
        }
    }

    private func handle(_ requestLine: String, body: Data, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "", path = parts.count > 1 ? String(parts[1]) : "/"
        switch (method, path) {
        case ("GET", "/"):
            respond(connection, type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case ("GET", "/events"):
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            streams.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else { if case .failed = state { connection.cancel() }; return }
                MainActor.assumeIsolated { self?.streams.removeAll { $0 === connection } }
            }
        case ("POST", "/result"):
            respond(connection, type: "text/plain", body: Data())
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let pending = pendingResult {
                pendingResult = nil
                pending.resume(returning: text)
            } else {
                earlyResult = text
            }
        default:
            respond(connection, type: "text/plain", body: Data(), status: path == "/log" ? "200 OK" : "404 Not Found")
        }
    }

    private func respond(_ connection: NWConnection, type: String, body: Data, status: String = "200 OK") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Sends a command to every open page; nil sends a keep-alive comment.
    private func broadcast(_ command: String?) {
        let message = Data((command.map { "data: \($0)\n\n" } ?? ": ping\n\n").utf8)
        for stream in streams {
            stream.send(content: message, completion: .contentProcessed { error in
                if error != nil { stream.cancel() }
            })
        }
    }

    private static let page = """
        <!doctype html><meta charset="utf-8"><title>MicFlow: voice typing</title>
        <body style="font:15px -apple-system,sans-serif;padding:24px;max-width:560px;color:#222">
        <h2>MicFlow: voice typing</h2>
        <p><b>Keep this tab open.</b> It can stay in the background or minimized. MicFlow uses it to
        recognize English and Bengali. Allow the microphone if the browser asks.</p>
        <p id="state" style="color:#666">Connecting…</p><p id="heard" style="font-size:20px"></p>
        <script>
        const state = document.getElementById('state'), heard = document.getElementById('heard');
        let rec = null, text = '';
        const events = new EventSource('/events');
        const ready = 'Ready. Hold one of your MicFlow voice keys and speak.';
        events.onopen = () => state.textContent = ready;
        events.onerror = () => state.textContent = 'Waiting for MicFlow…';
        events.onmessage = e => {
          if (e.data.startsWith('start')) start(e.data.split(':')[1] || 'bn-BD');
          if (e.data === 'stop' && rec) rec.stop();
        };
        function start(lang) {
          if (rec) { try { rec.abort(); } catch (e) {} }
          text = ''; heard.textContent = '';
          rec = new webkitSpeechRecognition();
          rec.lang = lang; rec.continuous = true; rec.interimResults = true;
          rec.onstart = () => state.textContent = 'Listening (' + lang + ')…';
          rec.onresult = ev => {
            let interim = '';
            for (let i = ev.resultIndex; i < ev.results.length; i++) {
              if (ev.results[i].isFinal) text += ev.results[i][0].transcript + ' ';
              else interim += ev.results[i][0].transcript;
            }
            heard.textContent = text + interim;
          };
          rec.onerror = ev => fetch('/log', {method: 'POST', body: 'error: ' + ev.error}).catch(() => {});
          rec.onend = () => {
            rec = null;
            state.textContent = ready;
            fetch('/result', {method: 'POST', body: text.trim()}).catch(() => {});
          };
          try { rec.start(); } catch (e) { fetch('/result', {method: 'POST', body: ''}).catch(() => {}); }
        }
        </script>
        """
}
