import Foundation

/// A transcription that runs while you speak: audio goes up in pieces as it's recorded and text
/// comes back as it's spoken, so it's ready almost as soon as the hotkey is released.
@MainActor
protocol LiveTranscriber: AnyObject {
    /// Called with the whole text so far each time it changes.
    var onText: (String) -> Void { get set }
    /// False once the connection has closed or failed.
    var isUsable: Bool { get }
    /// Sends newly recorded audio.
    func append(_ samples: [Float], sampleRate: Double)
    /// Sends the last of the audio and returns the text heard so far, within about a second.
    func finish(_ lastSamples: [Float]) async throws -> String
    /// Waits briefly for any last words, closes, and returns the full text.
    func settle() async -> String
    func cancel()
}

struct LiveTranscriptionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Turns recorded samples, arriving a piece at a time, into 16-bit little-endian mono PCM at a
/// fixed rate. Positions are counted from the start of the recording, so the pieces join up with
/// no seams.
struct PCMStreamer {
    let rate: Double
    private var input: [Float] = []
    private var sentFrames = 0

    init(rate: Double) { self.rate = rate }

    /// The PCM for everything that can be converted so far, and its loudness (RMS), or nil if
    /// there's nothing new yet.
    mutating func next(_ samples: [Float], inputRate: Double) -> (pcm: Data, frames: Int, level: Float)? {
        input.append(contentsOf: samples)
        // Frames that can be interpolated from what's arrived so far.
        let available = input.isEmpty ? 0 : Int(Double(input.count - 1) * rate / inputRate)
        guard available > sentFrames else { return nil }
        var pcm = Data(capacity: (available - sentFrames) * 2)
        var energy: Float = 0
        for i in sentFrames..<available {
            let position = Double(i) * inputRate / rate
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let value = input[index] + (input[index + 1] - input[index]) * fraction
            energy += value * value
            let sample = Int16(max(-1, min(1, value)) * 32_767)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let frames = available - sentFrames
        sentFrames = available
        return (pcm, frames, (energy / Float(frames)).squareRoot())
    }
}

/// Sends WebSocket text frames one after another, in order.
@MainActor
final class WebSocketSender {
    private let socket: URLSessionWebSocketTask
    private var chain: Task<Void, Never>?
    var onError: (Error) -> Void = { _ in }

    init(_ socket: URLSessionWebSocketTask) { self.socket = socket }

    func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let message = String(data: data, encoding: .utf8) else { return }
        let previous = chain
        chain = Task { [socket] in
            await previous?.value
            do {
                try await socket.send(.string(message))
            } catch {
                self.onError(error)
            }
        }
    }
}

extension URLSessionWebSocketTask.Message {
    /// The JSON object in a text or binary frame.
    var json: [String: Any]? {
        let data: Data
        switch self {
        case .string(let string): data = Data(string.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
