import Foundation

/// A piece that takes arguments: `\operatorname{RMSNorm}(□)`, `\frac{□}{□}`, `\sqrt{□}`.
/// `tex` holds the text around the slots, so arity = tex.count - 1.
struct Template: Hashable {
    let id: String
    let tex: [String]

    var arity: Int { tex.count - 1 }

    /// TeX with each slot filled in
    func render(_ args: [String]) -> String {
        var out = tex[0]
        for (i, arg) in args.enumerated() { out += arg + tex[i + 1] }
        return out
    }

    /// `\operatorname{RMSNorm}(□)`
    static func call(_ name: String, arity: Int = 1) -> Template {
        let head = name.hasPrefix("\\") ? name : #"\operatorname{\#(name)}"#
        return Template(id: "call:\(name)", tex: [head + "("] + Array(repeating: ",\\,", count: arity - 1) + [")"])
    }

    static let frac = Template(id: "frac", tex: [#"\frac{"#, "}{", "}"])
    static let sqrt = Template(id: "sqrt", tex: [#"\sqrt{"#, "}"])
    static let parens = Template(id: "parens", tex: [#"\left("#, #"\right)"#])
}

/// A built (or answer) expression: a sequence of atoms and templates with filled slots
indirect enum Expr: Hashable {
    case atom(String)
    case fn(Template, [[Expr]])

    /// Canonical TeX, used to compare answers
    static func tex(_ seq: [Expr]) -> String {
        seq.map { e in
            switch e {
            case .atom(let t): t
            case .fn(let tpl, let args): tpl.render(args.map { "{" + tex($0) + "}" })
            }
        }.joined(separator: " ")
    }

    /// Every tile used, as bank entries (atoms and templates), with repeats
    static func tiles(_ seq: [Expr]) -> [TileKind] {
        seq.flatMap { e -> [TileKind] in
            switch e {
            case .atom(let t): [.atom(t)]
            case .fn(let tpl, let args): [.fn(tpl)] + args.flatMap(tiles)
            }
        }
    }
}

enum TileKind: Hashable {
    case atom(String)
    case fn(Template)

    /// TeX for the tile label, with □ for slots
    var labelTeX: String {
        switch self {
        case .atom(let t): t
        case .fn(let tpl): tpl.render(Array(repeating: #"\square"#, count: tpl.arity))
        }
    }
}

// MARK: - Editable tree

/// Mutable version of an expression for the editor. Each sequence and node has an id so
/// taps inside the rendered TeX can find them.
final class EditSeq: Identifiable {
    let id = UUID()
    var nodes: [EditNode] = []
    weak var parent: EditNode?

    init(parent: EditNode? = nil) { self.parent = parent }

    var expr: [Expr] { nodes.map(\.expr) }
}

final class EditNode: Identifiable {
    let id = UUID()
    let kind: TileKind
    var args: [EditSeq] = []
    weak var owner: EditSeq?

    init(_ kind: TileKind, owner: EditSeq) {
        self.kind = kind
        self.owner = owner
        if case .fn(let tpl) = kind {
            args = (0..<tpl.arity).map { _ in EditSeq() }
            args.forEach { $0.parent = self }
        }
    }

    var expr: Expr {
        switch kind {
        case .atom(let t): .atom(t)
        case .fn(let tpl): .fn(tpl, args.map(\.expr))
        }
    }

    var tiles: [TileKind] { [kind] + args.flatMap { $0.nodes.flatMap(\.tiles) } }
}

extension Expr {
    /// Use a whole built expression as a single decoy tile
    var asTile: TileKind {
        switch self {
        case .atom(let t): .atom(t)
        case .fn: .atom(Expr.tex([self]))
        }
    }
}
