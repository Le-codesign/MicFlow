import Foundation

/// Gemini's live speech-to-text (`gemini-3.5-transcribe-live` over the Live API WebSocket). It only
/// writes down what's said, never replies, and handles English and Bengali mixed in one sentence.
/// "Smart" mode drops filler words and punctuates as it goes. The server finalizes a segment at
/// each pause; releasing the hotkey sends the end of the audio, which flushes the last one.
@MainActor
final class GeminiLiveTranscriber: LiveTranscriber {
    static let model = "gemini-3.5-transcribe-live"
    private static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    var onText: (String) -> Void = { _ in }

    private let socket: URLSessionWebSocketTask
    private let sender: WebSocketSender
    /// The API takes 16 kHz mono 16-bit PCM.
    private var streamer = PCMStreamer(rate: 16_000)
    private var inputRate: Double
    private var failure: LiveTranscriptionFailure?
    private var closed = false
    /// Audio can only be sent once the server has accepted the setup; until then it waits here.
    private var ready = false
    private var waiting: [[String: Any]] = []

    // Finished segments, and the server's current guess at the one being spoken.
    private var finals = ""
    private var interim = ""
    private var ended = false
    private var finalAfterEnd = false
    private var turnComplete = false
    /// Whether speech was sent since the last finished segment: then a final segment is still due.
    private var speechSinceFinal = false
    /// RMS above this counts as speech rather than silence or background noise.
    private static let speechLevel: Float = 0.02

    var isUsable: Bool { !closed && failure == nil }

    var text: String {
        Self.spaceSentences(Self.join(finals, interim)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(key: String, inputRate: Double) {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        socket = URLSession.shared.webSocketTask(with: components.url!)
        sender = WebSocketSender(socket)
        self.inputRate = inputRate
        sender.onError = { [weak self] in self?.fail(Self.describe($0, socket: nil)) }
        socket.resume()
        // Only English and Bengali. With no list it picks from 85+ languages, and Bengali after
        // English could come back as Hindi written in Latin letters. It still mixes the two.
        // No `customVocabulary`: with a word in it, the model writes that word into pauses and
        // unclear sounds even when nobody said it ("Figma" in 2 of 3 tests where it was never
        // spoken, and right without it). The user's words fix spelling afterwards instead.
        let transcription: [String: Any] = ["languageCodes": ["en-US", "bn-BD"], "mode": "SMART"]
        // Sent ahead of everything else; audio waits for `setupComplete`.
        sender.send(["setup": [
            "model": "models/\(Self.model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
        ]])
        Task { await receiveLoop() }
    }

    func append(_ samples: [Float], sampleRate: Double) {
        guard !closed else { return }
        inputRate = sampleRate
        guard let chunk = streamer.next(samples, inputRate: sampleRate) else { return }
        if chunk.level > Self.speechLevel { speechSinceFinal = true }
        send(["realtimeInput": ["audio": ["data": chunk.pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// Sends the end of the audio and returns what's been heard within about a second, so it can be
    /// pasted at once. Words still on their way come from `settle()`.
    func finish(_ lastSamples: [Float]) async throws -> String {
        append(lastSamples, sampleRate: inputRate)
        send(["realtimeInput": ["audioStreamEnd": true]])
        ended = true
        try await wait(upTo: 0.8)
        if let failure, text.isEmpty { close(); throw failure }
        return text
    }

    /// Waits a few more seconds for the words spoken just before the key was released (the server
    /// runs a little behind the voice), then closes. Returns the full text.
    func settle() async -> String {
        try? await wait(upTo: 3)
        close()
        return text
    }

    private func wait(upTo limit: Double) async throws {
        let start = Date()
        while failure == nil, !closed, !turnComplete {
            let pending = !interim.isEmpty || speechSinceFinal
            if !pending, finalAfterEnd || Date().timeIntervalSince(start) > 0.3 { break }
            if Date().timeIntervalSince(start) > limit { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func cancel() { close() }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        if ready {
            sender.send(event)
        } else {
            waiting.append(event)
        }
    }

    private func receiveLoop() async {
        while !closed {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if !closed { fail(Self.describe(error, socket: socket)) }
                return
            }
            guard let json = message.json else { continue }
            handle(json)
        }
    }

    private func handle(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            ready = true
            waiting.forEach(sender.send)
            waiting = []
        }
        if let error = json["error"] as? [String: Any] {
            fail(LiveTranscriptionFailure(message: ProviderName.hide(error["message"] as? String ?? "Model 1 returned an error.")))
        }
        guard let content = json["serverContent"] as? [String: Any] else { return }
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !final.isEmpty {
            finals = Self.join(finals, final)
            interim = ""
            speechSinceFinal = false
            if ended { finalAfterEnd = true }
            onText(text)
        }
        if let guess = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            interim = guess
            onText(text)
        }
        if ended, content["turnComplete"] as? Bool == true { turnComplete = true }
    }

    private func fail(_ error: LiveTranscriptionFailure) {
        if failure == nil { failure = error }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Joins pieces of text with a space, unless one is already there.
    private static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        return a.last!.isWhitespace || b.first!.isWhitespace ? a + b : a + " " + b
    }

    /// Segments can arrive glued together ("…ka.কিন্তু", "help.But"): puts a space after a sentence
    /// ending that runs straight into a capital letter or Bengali text. (Lower-case words are left
    /// alone, so web addresses and decimals keep their dots.)
    private static func spaceSentences(_ text: String) -> String {
        text.replacingOccurrences(of: "(?<=[.?!।])(?=[A-Z\\u0980-\\u09FF])", with: " ", options: .regularExpression)
    }

    /// The server explains a refused setup (a bad key, an unknown model) in the close reason.
    private static func describe(_ error: Error, socket: URLSessionWebSocketTask?) -> LiveTranscriptionFailure {
        if let reason = socket?.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty {
            return LiveTranscriptionFailure(message: "Model 1: \(ProviderName.hide(reason))")
        }
        if let error = error as? URLError, error.code == .badServerResponse || error.code == .userAuthenticationRequired {
            return LiveTranscriptionFailure(message: "Model 1 refused the connection. Check your API key.")
        }
        return LiveTranscriptionFailure(message: "Couldn't reach Model 1: \(error.localizedDescription)")
    }
}
