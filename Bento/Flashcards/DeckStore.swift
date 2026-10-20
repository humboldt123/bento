import Foundation
import Observation

/// Decks live in Notion (Bento › Decks and Cards). This keeps the last copy on disk so the app
/// opens instantly and works offline, refreshes from Notion, and writes study progress back.
@MainActor
@Observable
final class DeckStore {
    static let shared = DeckStore()

    private(set) var decks: [Deck] = []
    /// Why the last refresh failed, if it did
    private(set) var problem: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    /// Card id -> Notion page id, for writing progress back
    private var pageIds: [String: String] = [:]

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("decks.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            decks = (root["decks"] as? [[String: Any]] ?? []).map(DeckJSON.deck)
            pageIds = root["pageIds"] as? [String: String] ?? [:]
        }
    }

    /// Refresh at most every few minutes unless forced
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 300 { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let api = NotionAPI(),
              let decksDB = NotionAPI.database("DecksDatabase"),
              let cardsDB = NotionAPI.database("CardsDatabase") else {
            problem = "Add the Notion secret and deck database ids to Config.xcconfig."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let deckRows = api.queryAll(decksDB, sorts: [["property": "Order", "direction": "ascending"]])
            async let cardRows = api.queryAll(cardsDB, sorts: [["property": "Order", "direction": "ascending"]])
            let (deckPages, cardPages) = try await (deckRows, cardRows)

            var byDeck: [String: [[String: Any]]] = [:]
            var ids: [String: String] = [:]
            for page in cardPages {
                guard let deckId = page.select("Deck"),
                      var card = (try? JSONSerialization.jsonObject(with: Data(page.text("Data").utf8))) as? [String: Any] else { continue }
                let cardId = page.text("Card ID")
                card["id"] = cardId
                card["kind"] = page.select("Kind") ?? card["kind"] ?? "flip"
                byDeck[deckId, default: []].append(card)
                ids[cardId] = page.id
                StudyProgress.shared.merge(cardId: cardId, box: page.number("Box").map(Int.init),
                                           due: page.date("Due"), reviewed: page.date("Reviewed"))
            }
            let raw: [[String: Any]] = deckPages.map { page in
                let id = page.text("Deck ID")
                return ["id": id, "title": page.text("Name"), "subtitle": page.text("Subtitle"),
                        "symbol": page.text("Symbol"), "cards": byDeck[id] ?? []]
            }
            decks = raw.map(DeckJSON.deck)
            pageIds = ids
            problem = nil
            lastRefresh = .now
            if let data = try? JSONSerialization.data(withJSONObject: ["decks": raw, "pageIds": ids]) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Writes one card's progress to its Notion row (fire and forget; the next refresh reconciles)
    func push(cardId: String, box: Int?, due: Date?, reviewed: Date) {
        guard let page = pageIds[cardId], let api = NotionAPI() else { return }
        Task {
            try? await api.update(page: page, properties: [
                "Box": NotionAPI.number(box.map(Double.init)),
                "Due": NotionAPI.date(due),
                "Reviewed": NotionAPI.date(reviewed),
            ])
        }
    }
}

/// Deck and card JSON, the format stored in the Cards database's "Data" column:
///
///     flip:     { front, back, tag?, diagram? }
///     choice, cloze, match, sort, order, grid, flaw, tag: rendered by CardEngine
///     assemble: { prompt, answer: [Expr], alternates?, decoys?, glossary?: [[symbol, meaning]], explain? }
///     uml:      { name, intent, diagram }
///     unit:     { name, symbol, unit, expanded, built?: [left, op, right], formula, note?, group }
///
/// Expr: "tex" for an atom, or { fn: "frac" | "sqrt" | "parens" | { call, arity }, args: [[Expr]] }.
/// Diagram: { boxes: [{ id, name?, col, row, members?, interface? }], edges: [[from, kind, to]] }.
enum DeckJSON {
    static func deck(_ root: [String: Any]) -> Deck {
        let id = root["id"] as? String ?? ""
        var deck = Deck(id: id,
                        title: root["title"] as? String ?? id,
                        subtitle: root["subtitle"] as? String ?? "",
                        symbol: (root["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "rectangle.on.rectangle")
        for raw in root["cards"] as? [[String: Any]] ?? [] {
            guard let cardId = raw["id"] as? String else { continue }
            switch raw["kind"] as? String ?? "flip" {
            case "assemble": if let q = assemble(raw, id: cardId) { deck.quizzes.append(q) }
            case "uml":
                if let d = (raw["diagram"] as? [String: Any]).flatMap(diagram) {
                    deck.uml.append(UMLQuiz(name: raw["name"] as? String ?? "", intent: raw["intent"] as? String ?? "", diagram: d))
                }
            case "unit": if let q = unit(raw) { deck.ladder.append(q) }
            case "flip":
                deck.cards.append(Flashcard(id: cardId, front: raw["front"] as? String ?? "", back: raw["back"] as? String ?? "",
                                            diagram: (raw["diagram"] as? [String: Any]).flatMap(diagram), tag: raw["tag"] as? String))
            case let kind:
                let front = raw["front"] as? String ?? raw["prompt"] as? String
                    ?? (raw["text"] as? String)?.replacing(/\[\[\d+\]\]/, with: "___") ?? ""  // cloze cards have no prompt
                let payload = (try? JSONSerialization.data(withJSONObject: raw)).flatMap { String(data: $0, encoding: .utf8) }
                deck.cards.append(Flashcard(id: cardId, front: front, back: raw["why"] as? String ?? "",
                                            tag: raw["tag"] as? String, kind: kind, payload: payload))
            }
        }
        return deck
    }

    // MARK: Pieces

    private static func diagram(_ d: [String: Any]) -> UMLDiagram? {
        let boxes = (d["boxes"] as? [[String: Any]] ?? []).compactMap { b -> UMLDiagram.Box? in
            guard let id = b["id"] as? String, let col = b["col"] as? Int, let row = b["row"] as? Int else { return nil }
            return UMLDiagram.Box(id: id, name: b["name"] as? String ?? id, members: b["members"] as? [String] ?? [],
                                  isInterface: b["interface"] as? Bool ?? false, col: col, row: row)
        }
        let edges = (d["edges"] as? [[String]] ?? []).compactMap { e -> UMLDiagram.Edge? in
            guard e.count == 3, let kind = UMLDiagram.Kind(name: e[1]) else { return nil }
            return UMLDiagram.Edge(from: e[0], to: e[2], kind: kind)
        }
        return boxes.isEmpty ? nil : UMLDiagram(boxes: boxes, edges: edges)
    }

    private static func assemble(_ raw: [String: Any], id: String) -> AssembleQuiz? {
        guard let answer = (raw["answer"] as? [Any]).map(exprs) else { return nil }
        return AssembleQuiz(
            id: id,
            prompt: raw["prompt"] as? String ?? "",
            answer: answer,
            alternates: (raw["alternates"] as? [[Any]] ?? []).map(exprs),
            decoys: (raw["decoys"] as? [Any] ?? []).compactMap(tile),
            glossary: (raw["glossary"] as? [[String]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
            explain: raw["explain"] as? String ?? ""
        )
    }

    private static func unit(_ raw: [String: Any]) -> UnitQuantity? {
        guard let name = raw["name"] as? String else { return nil }
        let built = (raw["built"] as? [String]).flatMap { $0.count == 3 ? ($0[0], $0[1], $0[2]) : nil }
        return UnitQuantity(name: name, symbol: raw["symbol"] as? String ?? "", unit: raw["unit"] as? String ?? "",
                            expanded: raw["expanded"] as? String ?? "", built: built, formula: raw["formula"] as? String ?? "",
                            note: raw["note"] as? String, group: raw["group"] as? String ?? "")
    }

    private static func exprs(_ list: [Any]) -> [Expr] { list.compactMap(expr) }

    private static func expr(_ any: Any) -> Expr? {
        if let s = any as? String { return .atom(s) }
        guard let d = any as? [String: Any], let tpl = d["fn"].flatMap(template) else { return nil }
        return .fn(tpl, (d["args"] as? [[Any]] ?? []).map(exprs))
    }

    private static func tile(_ any: Any) -> TileKind? {
        if let s = any as? String { return .atom(s) }
        return ((any as? [String: Any])?["fn"]).flatMap(template).map { .fn($0) }
    }

    private static func template(_ any: Any) -> Template? {
        switch any {
        case "frac" as String: return .frac
        case "sqrt" as String: return .sqrt
        case "parens" as String: return .parens
        case let d as [String: Any]:
            guard let name = d["call"] as? String else { return nil }
            return .call(name, arity: d["arity"] as? Int ?? 1)
        default: return nil
        }
    }
}

extension UMLDiagram.Kind {
    init?(name: String) {
        switch name {
        case "inherits": self = .inherits
        case "implements": self = .implements
        case "has": self = .has
        case "hasMany": self = .hasMany
        case "uses": self = .uses
        case "creates": self = .creates
        default: return nil
        }
    }
}
