import AppKit
import Carbon.HIToolbox
import CoreAudio
import os
import Security

/// A secret (an API key or token) kept in the login Keychain rather than in preferences.
struct KeychainSecret {
    /// The Gemini API key, for voice typing.
    static let geminiKey = KeychainSecret(service: "local.micboost.gemini-api-key")

    let service: String

    /// Whether a secret is saved, without reading it. Reading the secret itself makes macOS ask for
    /// permission after every rebuild of the app, so only do that when it's actually used.
    func exists() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func save(_ key: String) -> Bool {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecValueData as String: Data(key.utf8)]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// Records one input device into memory as mono samples.
final class VoiceRecorder {
    /// Five minutes at 48 kHz; anything longer is cut off.
    private static let maxSamples = 48_000 * 300
    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])
    private let currentLevel = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate = 48_000.0

    /// Records `input`, made `gain` times louder. A limiter turns loud moments down so the boosted
    /// voice never clips.
    func start(_ input: AudioDevice, gain: Float = 1) throws {
        stopDevice()
        samples.withLock { $0.removeAll(keepingCapacity: true) }
        device = input.id
        sampleRate = CA.nominalSampleRate(input.id) ?? 48_000
        let samples = self.samples
        let currentLevel = self.currentLevel
        let ceiling: Float = 0.9
        // The limiter lets go over about a quarter of a second.
        let release = Float(exp(-1 / (0.25 * sampleRate)))
        var envelope: Float = 0
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, input.id, nil) { _, inputData, _, _, _ in
            guard let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)).first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { return }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (channels * 4)
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                let boosted = sum / Float(channels) * gain
                envelope = max(abs(boosted), envelope * release)
                mono[frame] = envelope > ceiling ? boosted * ceiling / envelope : boosted
            }
            let done = mono
            samples.withLock { if $0.count < Self.maxSamples { $0.append(contentsOf: done) } }
            let rms = done.isEmpty ? 0 : (done.reduce(Float(0)) { $0 + $1 * $1 } / Float(done.count)).squareRoot()
            currentLevel.withLock { $0 = rms }
        }
        guard status == noErr else { throw BoostError.coreAudio("Opening \(input.name)", status) }
        status = AudioDeviceStart(input.id, procID)
        guard status == noErr else { throw BoostError.coreAudio("Starting \(input.name)", status) }
    }

    /// Stops and returns what was recorded.
    func stop() -> [Float] {
        stopDevice()
        currentLevel.withLock { $0 = 0 }
        return samples.withLock { $0 }
    }

    private func stopDevice() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    /// How loud the latest sound was (RMS), for a level meter.
    var level: Float { currentLevel.withLock { $0 } }

    /// The samples recorded since `start` (a count of samples), for sending audio while recording.
    func samples(from start: Int) -> [Float] {
        samples.withLock { start < $0.count ? Array($0[start...]) : [] }
    }
}

/// Gemini's REST API, used to check that a pasted key works before saving it.
enum GeminiClient {
    private static let base = "https://generativelanguage.googleapis.com/v1beta"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Succeeds when Google accepts the key.
    static func check(key: String) async throws {
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=1")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure(message: ProviderName.hide(message ?? "This key wasn't accepted."))
        }
    }
}

/// Names for hotkeys, by virtual key code.
enum KeyNames {
    /// Modifier keys and the flag that's set while each is held.
    static let modifierFlags: [Int64: CGEventFlags] = [
        Int64(kVK_RightControl): .maskControl, Int64(kVK_Control): .maskControl,
        Int64(kVK_RightCommand): .maskCommand, Int64(kVK_Command): .maskCommand,
        Int64(kVK_RightOption): .maskAlternate, Int64(kVK_Option): .maskAlternate,
        Int64(kVK_RightShift): .maskShift, Int64(kVK_Shift): .maskShift,
        Int64(kVK_Function): .maskSecondaryFn,
    ]

    /// The flag bit for one side's modifier key, e.g. only the right Ctrl (from IOKit's
    /// NX_DEVICE…KEYMASK). The general flags above stay set while the other side's key is held,
    /// which would hide this key's release.
    static let sideFlags: [Int64: UInt64] = [
        Int64(kVK_Control): 0x0000_0001, Int64(kVK_RightControl): 0x0000_2000,
        Int64(kVK_Shift): 0x0000_0002, Int64(kVK_RightShift): 0x0000_0004,
        Int64(kVK_Command): 0x0000_0008, Int64(kVK_RightCommand): 0x0000_0010,
        Int64(kVK_Option): 0x0000_0020, Int64(kVK_RightOption): 0x0000_0040,
    ]

    /// Whether this modifier key is down in an event, judged by its own side where possible.
    static func isDown(_ keyCode: Int64, in flags: CGEventFlags) -> Bool {
        if let bit = sideFlags[keyCode] { return flags.rawValue & bit != 0 }
        return modifierFlags[keyCode].map(flags.contains) ?? false
    }

    private static let names: [Int: String] = [
        kVK_RightControl: "Right Ctrl", kVK_Control: "Left Ctrl",
        kVK_RightCommand: "Right Cmd (Windows)", kVK_Command: "Left Cmd (Windows)",
        kVK_RightOption: "Right Alt (Option)", kVK_Option: "Left Alt (Option)",
        kVK_RightShift: "Right Shift", kVK_Shift: "Left Shift", kVK_Function: "Fn",
        kVK_Space: "Space", kVK_Escape: "Escape", kVK_Tab: "Tab", kVK_Return: "Return",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_Help: "Insert", kVK_ForwardDelete: "Delete",
    ]

    static func name(_ keyCode: Int64, characters: String? = nil) -> String {
        if let name = names[Int(keyCode)] { return name }
        if let characters, !characters.isEmpty { return characters.uppercased() }
        return "Key \(keyCode)"
    }
}

/// MicFlow doesn't say which company's models it uses. Messages that come from the service itself
/// (a refused key, a used-up quota) can name it, so those names are taken out before they're shown.
enum ProviderName {
    static func hide(_ message: String) -> String {
        let replacements: [(String, String)] = [
            ("generativelanguage\\.googleapis\\.com", "the service"),
            ("(Google )?AI Studio", "your provider's dashboard"),
            ("Generative Language API", "the API"),
            ("Gemini API", "the API"),
            ("gemini-[0-9a-z.\\-]+", "the model"),
            ("Gemini", "the model"),
            ("Google Cloud", "the provider"),
            ("Google", "the provider"),
        ]
        return replacements.reduce(message) { text, pair in
            text.replacingOccurrences(of: pair.0, with: pair.1, options: [.regularExpression, .caseInsensitive])
        }
    }
}
