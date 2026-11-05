import CryptoKit
import Foundation

/// Locks the API key before it's saved to the account, so the database only ever holds a sealed
/// copy: AES-GCM with a key made from a secret inside the app and the person's own account id.
/// The sealed copy can only be opened by MicFlow, signed in as that same person; the database on
/// its own (or anyone browsing it) can't read or use the key.
///
/// Never change `partA`/`partB`: keys sealed with them could no longer be opened.
enum KeyVault {
    private static let partA: [UInt8] = [0xEF, 0x38, 0x5C, 0x41, 0x37, 0xBA, 0xB7, 0x49, 0xEE, 0x46, 0x9B, 0xEA, 0x57, 0x9B, 0xC3, 0x33,
                                         0x4E, 0x2D, 0x1A, 0x42, 0xA2, 0x04, 0xAA, 0xC4, 0xF8, 0x8B, 0xED, 0xAF, 0x78, 0xC4, 0xD0, 0x1C]
    private static let partB: [UInt8] = [0xDA, 0xD9, 0x57, 0xBF, 0x4A, 0x67, 0x9C, 0xB6, 0xA4, 0x8F, 0x20, 0xAD, 0x15, 0x4D, 0xE9, 0x0A,
                                         0x91, 0x7A, 0x82, 0x77, 0xAE, 0xB6, 0x8F, 0xBE, 0x3A, 0xD9, 0x11, 0x54, 0xE7, 0x80, 0xE8, 0x6D]
    private static let prefix = "mf1:"

    private static func key(for user: String) -> SymmetricKey {
        let secret = SymmetricKey(data: zip(partA, partB).map { $0 ^ $1 })
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: Data(user.utf8),
                                      info: Data("MicFlow API key v1".utf8), outputByteCount: 32)
    }

    static func seal(_ apiKey: String, user: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(apiKey.utf8), using: key(for: user)), let combined = box.combined else { return nil }
        return prefix + combined.base64EncodedString()
    }

    /// The key from a sealed copy. A plain key (saved by an older version) is returned as it is.
    static func open(_ stored: String, user: String) -> String? {
        guard stored.hasPrefix(prefix) else { return stored.isEmpty ? nil : stored }
        guard let data = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key(for: user)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

/// Every setting you choose in MicFlow (shortcuts, remaps, mouse, sound, voice typing options),
/// saved to your account while you're signed in and brought back when you sign in on another Mac.
/// Things that belong to one Mac only (which microphone, window positions, update bookkeeping)
/// stay out.
enum SettingsSync {
    static let keys = [
        // Sound
        "enabled", "gainDB", "maxHardwareVolume", "speakerEnabled", "speakerGainDB",
        // Mouse
        "middleClickEnabled", "middleZoneWidth", "figmaZoomEnabled", "figmaZoomAmount",
        "scrollDistanceEnabled", "scrollDistance", "smoothScrollEnabled", "scrollSmoothness",
        "trackingSpeedEnabled", "trackingLevel", "swipeEnabled", "swipeLeftAction", "swipeRightAction",
        "mouseButtonsEnabled", "mouseButtonActions", "mouseButtonMappings",
        // Keyboard
        "keyRemapEnabled", "keyRemaps",
        // Capture
        "captureShortcuts", "captureCopyToClipboard", "captureTimerSeconds", "captureRecordMicrophone", "captureShortcutMap",
        // Voice typing
        "voiceTypingEnabled", "voiceTypingHotkey", "voiceTypingHotkeyName", "voiceTypingEnglishHotkey",
        "voiceTypingEnglishHotkeyName", "voiceTypingEngine", "voiceTypingFixMixUps", "voiceTypingPolish",
        // Look
        "homeDarkTheme", "selectedTab", "sidebarExpanded", "skipGoogleKeyGuide",
    ]

    /// The current settings, as JSON-friendly values (binary values as {"data": base64}).
    static func snapshot() -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] else { continue }
            if let encoded = encode(value) { result[key] = encoded }
        }
        return result
    }

    /// Writes the account's settings into this Mac's. Returns whether anything changed.
    @discardableResult
    static func apply(_ settings: [String: Any]) -> Bool {
        let current = snapshot()
        var changed = false
        for key in keys {
            guard let value = settings[key], !same(value, current[key]) else { continue }
            if let decoded = decode(value) {
                UserDefaults.standard.set(decoded, forKey: key)
                changed = true
            }
        }
        return changed
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return canonical(a) == canonical(b)
    }

    static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encode(_ value: Any) -> Any? {
        switch value {
        case let data as Data: return ["data": data.base64EncodedString()]
        case let date as Date: return date.timeIntervalSince1970
        case let array as [Any]: return array.compactMap(encode)
        case let dict as [String: Any]: return dict.compactMapValues(encode)
        case is NSNumber, is String: return value
        default: return nil
        }
    }

    private static func decode(_ value: Any) -> Any? {
        if let dict = value as? [String: Any], dict.count == 1, let base64 = dict["data"] as? String {
            return Data(base64Encoded: base64)
        }
        switch value {
        case let array as [Any]: return array.compactMap(decode)
        case let dict as [String: Any]: return dict.compactMapValues(decode)
        case is NSNull: return nil
        default: return value
        }
    }
}
