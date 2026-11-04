import Foundation

/// Every dictation: when, what was typed, and how long the key was held. Kept only on this Mac,
/// in Application Support, for the Home window's numbers and history.
@MainActor
final class DictationLog: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let text: String
        let words: Int
        /// How long the voice key was held.
        let seconds: Double
    }

    @Published private(set) var entries: [Entry] = []

    /// A typical typing speed, to work out the time voice typing saved.
    static let typingWPM = 40.0
    /// Older entries are dropped beyond this many.
    private static let limit = 5_000

    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("MicFlow", isDirectory: true)
        // The app used to be called Mic Boost; its history moves over the first time.
        moveIfNeeded(from: support.appendingPathComponent("Mic Boost", isDirectory: true), to: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("dictations.json")
    }()

    init() {
        entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func add(_ text: String, seconds: Double) {
        let words = Self.wordCount(text)
        guard words > 0 else { return }
        entries.append(Entry(date: Date(), text: text, words: words, seconds: seconds))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Numbers for the Home window

    var totalWords: Int { entries.reduce(0) { $0 + $1.words } }

    func words(on day: Date) -> Int {
        entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.words }
    }

    /// Words per minute of speaking, over every dictation.
    var averageWPM: Int {
        let minutes = entries.reduce(0) { $0 + $1.seconds } / 60
        return minutes > 0 ? Int((Double(totalWords) / minutes).rounded()) : 0
    }

    /// Minutes saved compared with typing the same words.
    var minutesSaved: Int {
        let speaking = entries.reduce(0) { $0 + $1.seconds } / 60
        return max(0, Int((Double(totalWords) / Self.typingWPM - speaking).rounded()))
    }

    /// Days in a row, up to today (or yesterday, if nothing yet today), with at least one dictation.
    var streak: Int {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    /// Words per day for the last seven days, oldest first.
    var lastSevenDays: [(day: Date, words: Int)] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).reversed().map { back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: today)!
            return (day, words(on: day))
        }
    }

    /// The share of words in Bengali script, from 0 to 1.
    var bengaliShare: Double {
        var bengali = 0, all = 0
        for entry in entries {
            for word in entry.text.split(whereSeparator: { $0.isWhitespace }) {
                all += 1
                if word.unicodeScalars.contains(where: { (0x0980...0x09FF).contains($0.value) }) { bengali += 1 }
            }
        }
        return all > 0 ? Double(bengali) / Double(all) : 0
    }
}

/// Moves a folder from the app's old name to the new one. If the new folder is already there, moves
/// over each file it doesn't have yet, and removes the old folder once it's empty.
func moveIfNeeded(from old: URL, to new: URL) {
    let files = FileManager.default
    guard files.fileExists(atPath: old.path) else { return }
    func move(_ from: URL, _ to: URL) {
        do { try files.moveItem(at: from, to: to) } catch { NSLog("MicFlow couldn't move %@: %@", from.path, error.localizedDescription) }
    }
    guard files.fileExists(atPath: new.path) else { return move(old, new) }
    for name in (try? files.contentsOfDirectory(atPath: old.path)) ?? [] where !files.fileExists(atPath: new.appendingPathComponent(name).path) {
        move(old.appendingPathComponent(name), new.appendingPathComponent(name))
    }
    if ((try? files.contentsOfDirectory(atPath: old.path)) ?? []).filter({ $0 != ".DS_Store" }).isEmpty {
        try? files.removeItem(at: old)
    }
}
