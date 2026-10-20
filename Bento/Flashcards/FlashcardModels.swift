import Foundation
import Observation

struct Flashcard: Identifiable, Hashable {
    let id: String
    let front: String
    let back: String
    /// Optional class diagram shown on the back
    var diagram: UMLDiagram?
    /// Small label above the front, e.g. "Structural"
    var tag: String?
    /// "flip", or an interactive kind ("choice", "cloze", "match", "sort", "order", "grid", "flaw", "tag")
    var kind = "flip"
    /// The full card as JSON for interactive kinds (rendered and graded by CardEngine)
    var payload: String?

    var isInteractive: Bool { kind != "flip" }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct Deck: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var cards: [Flashcard] = []
    /// "Build the equations" quizzes
    var quizzes: [AssembleQuiz] = []
    /// "Draw the UML" quizzes
    var uml: [UMLQuiz] = []
    /// Quantities for the Unit ladder screen
    var ladder: [UnitQuantity] = []
}

/// A row of the Unit ladder: how a quantity's unit is built from others
struct UnitQuantity: Identifiable {
    var id: String { name }
    let name: String
    let symbol: String
    /// TeX, e.g. "\\mathrm{Pa}"
    let unit: String
    let expanded: String
    /// (left, "×" or "÷", right); nil for base quantities
    let built: (String, String, String)?
    let formula: String
    var note: String?
    let group: String
}

/// Leitner boxes: right answers move a card up a box (seen less often), misses send it to box 0
@MainActor
@Observable
final class StudyProgress {
    static let shared = StudyProgress()

    private struct Entry: Codable {
        var box: Int
        var due: Date
        /// When this device last answered it; the newer review wins when syncing with Notion
        var reviewed: Date?
    }

    /// Days until a card in each box comes back
    private static let intervals = [0, 1, 3, 7, 16, 35]
    private static let key = "flashcardProgress"

    private var entries: [String: Entry]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func isDue(_ card: Flashcard, now: Date = .now) -> Bool {
        guard let e = entries[card.id] else { return true }
        return e.due <= now
    }

    func isNew(_ card: Flashcard) -> Bool { entries[card.id] == nil }

    func box(of card: Flashcard) -> Int { entries[card.id]?.box ?? 0 }

    func due(in deck: Deck) -> [Flashcard] {
        // Seen-but-due first, then new cards
        let due = deck.cards.filter { isDue($0) }
        return due.filter { !isNew($0) } + due.filter(isNew)
    }

    /// Fraction of cards that have made it past the first two boxes
    func mastery(of deck: Deck) -> Double {
        guard !deck.cards.isEmpty else { return 0 }
        return Double(deck.cards.filter { box(of: $0) >= 2 }.count) / Double(deck.cards.count)
    }

    func record(_ card: Flashcard, correct: Bool, now: Date = .now) {
        let box = correct ? min(box(of: card) + 1, Self.intervals.count - 1) : 0
        let days = correct ? Self.intervals[box] : 0
        // Misses come back later in the same session-ish (10 minutes)
        let due = correct
            ? Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now))!
            : now.addingTimeInterval(600)
        entries[card.id] = Entry(box: box, due: due, reviewed: now)
        save()
        DeckStore.shared.push(cardId: card.id, box: box, due: due, reviewed: now)
    }

    /// Progress read from Notion: adopted when it was reviewed more recently than what's here
    func merge(cardId: String, box: Int?, due: Date?, reviewed: Date?) {
        guard let reviewed, reviewed > (entries[cardId]?.reviewed ?? .distantPast) else { return }
        if let box, let due {
            entries[cardId] = Entry(box: box, due: due, reviewed: reviewed)
        } else {
            entries[cardId] = nil  // reset elsewhere
        }
        save()
    }

    func reset(_ deck: Deck) {
        for card in deck.cards {
            entries[card.id] = nil
            DeckStore.shared.push(cardId: card.id, box: nil, due: nil, reviewed: .now)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
