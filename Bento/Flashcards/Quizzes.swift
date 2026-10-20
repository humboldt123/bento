import Foundation

/// "Build it" quiz: real pieces plus look-alike decoys. Functions come with empty slots
/// you fill in, so structure (what goes inside what) is part of the answer.
struct AssembleQuiz: Identifiable {
    let id: String
    let prompt: String
    let answer: [Expr]
    /// Other correct forms (e.g. commuted terms)
    var alternates: [[Expr]] = []
    /// Wrong-but-tempting tiles
    var decoys: [TileKind] = []
    /// Symbol (TeX) -> what it means, shown under the prompt and on long-press
    var glossary: [(String, String)] = []
    /// Shown after checking
    var explain: String = ""

    func isCorrect(_ built: [Expr]) -> Bool {
        let tex = Expr.tex(built)
        return ([answer] + alternates).contains { Expr.tex($0) == tex }
    }

    /// Bank: every tile the answer uses, plus decoys
    var tiles: [TileKind] { Expr.tiles(answer) + decoys }

    func meaning(of tile: TileKind) -> String? {
        let key: String
        switch tile {
        case .atom(let t): key = t
        case .fn(let tpl): key = tpl.id.hasPrefix("call:") ? String(tpl.id.dropFirst(5)) : tpl.id
        }
        return glossary.first { $0.0 == key || $0.0.contains(key) }?.1
    }
}

/// "Draw the UML": a pattern's classes with the arrows hidden; pick each relationship
struct UMLQuiz: Identifiable {
    var id: String { name }
    let name: String
    let intent: String
    let diagram: UMLDiagram

    /// Every real edge, plus one pair with no relationship so "none" is a live answer
    var questions: [(from: String, to: String, answer: UMLDiagram.Kind?)] {
        var qs: [(String, String, UMLDiagram.Kind?)] = diagram.edges.map { ($0.from, $0.to, $0.kind) }
        let linked = Set(diagram.edges.flatMap { [$0.from + ">" + $0.to, $0.to + ">" + $0.from] })
        let ids = diagram.boxes.map(\.id)
        outer: for a in ids {
            for b in ids where a != b && !linked.contains(a + ">" + b) {
                qs.append((a, b, nil))
                break outer
            }
        }
        return qs.map { (from: $0.0, to: $0.1, answer: $0.2) }
    }
}
