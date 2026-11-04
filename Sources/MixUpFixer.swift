import Foundation

/// The user's word library: after dictation, words that were heard are written the user's way
/// ("figma" or "fig ma" becomes "Figma"). Only words already in the text change, so nothing can
/// appear that wasn't said, unlike handing the list to the speech model.
enum MyWords {
    static func spell(_ text: String, _ words: [String]) -> String {
        words.reduce(text) { text, word in
            // Letters may come out with spaces or hyphens between them, and in any case.
            let letters = word.filter { !$0.isWhitespace && $0 != "-" }
            guard !letters.isEmpty else { return text }
            let pattern = "(?<![\\p{L}\\p{N}])"
                + letters.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\-]?")
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: word))
        }
    }
}

/// A word the speaker says in a way that gets transcribed as another one, e.g. "world" coming out
/// as "word".
struct MixUp: Codable, Hashable, Identifiable {
    var id = UUID()
    /// What the transcription writes.
    var heard: String
    /// What the speaker may have meant.
    var meant: String
    /// What the meant word means, to tell the two apart; optional.
    var meaning: String = ""

    /// The first mix-up, set up for every new user: it's the one this feature was made for.
}
