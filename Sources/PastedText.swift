import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Swaps freshly pasted dictation for its cleaned-up version a moment later, never touching what
/// you've typed or changed since:
/// - In apps that share their text through Accessibility (most Mac apps), it finds the pasted words
///   by the text around them. If you edited some of them, only the words you didn't touch are
///   cleaned up. If they're gone (sent, deleted), nothing changes. Works for Bengali too.
/// - In apps that don't (Chrome, Electron apps such as Slack, WhatsApp or the Claude app), by
///   deleting the pasted text with Backspace and pasting the new one, only if you haven't pressed a
///   key or clicked since, you're in the same app, and the text has no Bengali, since Backspace
///   removes Bengali letters in uneven pieces.
@MainActor
struct PastedText {
    /// Marks the keys MicFlow presses itself, so they don't count as you typing.
    static let syntheticMarker: Int64 = 0x4D46_4C57

    let text: String
    let app: NSRunningApplication?
    /// Your key presses and clicks so far, and how many dictations were pasted, when this was pasted.
    let activity: Int
    let dictation: Int
    /// The field it went into and the text before and after it, when the app shares its text.
    private let field: AXUIElement?
    private let before: String
    private let after: String
    /// The clipboard's change count right after pasting.
    let clipboardChange: Int

    enum Outcome: String {
        case replaced = "replaced in the field"
        case merged = "cleaned up around your edits"
        case retyped = "retyped"
        case kept = "kept: the text was sent, changed, or you typed or clicked since"
    }

    /// Pastes `text` where the cursor is and remembers where it went.
    static func paste(_ text: String, activity: Int, dictation: Int) -> PastedText {
        var field: AXUIElement?
        var before = "", after = ""
        if let focused = focusedField(allowEmpty: true), let value: String = focused.copy(kAXValueAttribute),
           let selection = focused.selectedRange() {
            let all = value as NSString
            let start = min(max(selection.location, 0), all.length)
            let end = min(start + max(selection.length, 0), all.length)
            field = focused
            before = all.substring(to: start)
            after = all.substring(from: end)
        }
        paste(text)
        return PastedText(text: text, app: NSWorkspace.shared.frontmostApplication, activity: activity, dictation: dictation,
                          field: field, before: before, after: after, clipboardChange: NSPasteboard.general.changeCount)
    }

    func replace(with polished: String, activityNow: Int, dictationNow: Int) -> Outcome {
        // A newer dictation has been pasted after this one, or you've moved to another app.
        guard dictationNow == dictation, NSWorkspace.shared.frontmostApplication == app else { return .kept }
        if let field = Self.focusedField(), let value: String = field.copy(kAXValueAttribute) {
            switch replaceInField(field, value: value as NSString, with: polished) {
            case .done(let outcome): return outcome
            case .changed: return .kept
            // The app took the change but ignored it: try with keys below.
            case .ignored: break
            }
        }
        guard activityNow == activity, text.unicodeScalars.allSatisfy({ $0.value < 0x0900 }) else { return .kept }
        Self.press(kVK_Delete, times: text.count)
        Self.paste(polished)
        return .retyped
    }

    private enum FieldResult { case done(Outcome), changed, ignored }

    private func replaceInField(_ field: AXUIElement, value: NSString, with polished: String) -> FieldResult {
        // Where the pasted words are now: between the text that was before and after them.
        let range: NSRange
        let current: String
        if let remembered = self.field, CFEqual(remembered, field),
           value.length >= (before as NSString).length + (after as NSString).length,
           value.hasPrefix(before), value.hasSuffix(after) {
            range = NSRange(location: (before as NSString).length,
                            length: value.length - (before as NSString).length - (after as NSString).length)
            current = value.substring(with: range)
        } else if let cursor = field.selectedRange(), cursor.length == 0 {
            // Otherwise only if the text just before the cursor is exactly what was pasted.
            let count = (text as NSString).length
            guard cursor.location - count >= 0, cursor.location <= value.length,
                  value.substring(with: NSRange(location: cursor.location - count, length: count)) == text else { return .changed }
            range = NSRange(location: cursor.location - count, length: count)
            current = text
        } else {
            return .changed
        }
        // Gone: sent, deleted, or replaced by you.
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .changed }
        let edited = current != text
        let new = edited ? WordMerge.merge(base: text, yours: current, cleaned: polished) : polished
        guard new != current else { return .changed }
        let cursor = field.selectedRange()
        var target = CFRange(location: range.location, length: range.length)
        guard let targetValue = AXValueCreate(.cfRange, &target),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, targetValue) == .success,
              AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, new as CFString) == .success else {
            return .ignored
        }
        let newLength = (new as NSString).length
        guard let now: String = field.copy(kAXValueAttribute), (now as NSString).length >= range.location + newLength,
              (now as NSString).substring(with: NSRange(location: range.location, length: newLength)) == new else {
            if let cursor { Self.select(field, location: cursor.location, length: cursor.length) }
            return edited ? .changed : .ignored
        }
        // The cursor stays where it was, moved along by the change if it was after the words.
        let end = range.location + range.length
        if let cursor, cursor.location < range.location {
            Self.select(field, location: cursor.location, length: cursor.length)
        } else if let cursor, cursor.location >= end {
            Self.select(field, location: cursor.location + newLength - range.length, length: cursor.length)
        } else {
            Self.select(field, location: range.location + newLength, length: 0)
        }
        return .done(edited ? .merged : .replaced)
    }

    private static func select(_ field: AXUIElement, location: Int, length: Int) {
        var range = CFRange(location: max(location, 0), length: max(length, 0))
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
        }
    }

    /// The focused text field, if its app shares its text. Chrome and Electron apps say they do but
    /// leave it empty, so a field with no text counts as not sharing.
    private static func focusedField(allowEmpty: Bool = false) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // A busy app mustn't freeze MicFlow.
        AXUIElementSetMessagingTimeout(system, 0.3)
        guard let field: AXUIElement = system.copy(kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.3)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
              let value: String = field.copy(kAXValueAttribute), allowEmpty || !value.isEmpty else { return nil }
        return field
    }

    /// Puts the text on the clipboard and pastes it with Cmd-V. It stays on the clipboard, so it can
    /// be pasted again anywhere.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(kVK_ANSI_V, flags: .maskCommand)
    }

    private static func press(_ key: Int, flags: CGEventFlags = [], times: Int = 1) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<times {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown) else { continue }
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

private extension AXUIElement {
    func copy<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func selectedRange() -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

/// Cleans up only the words you haven't changed: the changes between the pasted text and the
/// cleaned-up one are applied to your edited version wherever you left those words as they were.
enum WordMerge {
    static func merge(base: String, yours: String, cleaned: String) -> String {
        let b = tokens(base), y = tokens(yours), c = tokens(cleaned)
        // Where each pasted word is in your version, if you left it alone.
        var inYours = [Int?](repeating: nil, count: b.count)
        for (i, j) in matches(b, y) { inYours[i] = j }
        func position(_ i: Int) -> Int? { i < 0 ? -1 : i >= b.count ? y.count : inYours[i] }
        var result = y
        // Each stretch the clean-up changed, from the end so earlier positions stay right.
        for hunk in hunks(b, c, matches(b, c)).reversed() {
            guard let left = position(hunk.base.lowerBound - 1), let right = position(hunk.base.upperBound),
                  right - left == hunk.base.count + 1,
                  hunk.base.allSatisfy({ inYours[$0] != nil }) else { continue }
            result.replaceSubrange((left + 1)..<right, with: c[hunk.cleaned])
        }
        return result.joined()
    }

    /// Words and the spaces between them, so joining them gives the text back.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace: Bool?
        for character in text {
            let space = character.isWhitespace
            if let inSpace, inSpace != space { out.append(current); current = "" }
            current.append(character)
            inSpace = space
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The longest run of tokens the two have in common, in order, as index pairs.
    private static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    private static func hunks(_ a: [String], _ b: [String], _ pairs: [(Int, Int)]) -> [(base: Range<Int>, cleaned: Range<Int>)] {
        var out: [(base: Range<Int>, cleaned: Range<Int>)] = []
        var lastA = -1, lastB = -1
        for (i, j) in pairs + [(a.count, b.count)] {
            if i > lastA + 1 || j > lastB + 1 { out.append((base: (lastA + 1)..<i, cleaned: (lastB + 1)..<j)) }
            lastA = i; lastB = j
        }
        return out
    }
}
