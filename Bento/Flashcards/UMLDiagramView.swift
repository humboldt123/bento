import SwiftUI

/// A tiny class diagram laid out on a 3-column grid
struct UMLDiagram: Hashable {
    struct Box: Hashable {
        let id: String
        let name: String
        var members: [String] = []
        /// «interface» / abstract classes render in italics with a stereotype
        var isInterface = false
        let col: Int
        let row: Int
    }

    enum Kind: Hashable {
        case inherits    // solid line, hollow triangle
        case implements  // dashed line, hollow triangle
        case has         // solid line, diamond at the owner
        case hasMany     // like has, with "*"
        case uses        // solid line, open arrow
        case creates     // dashed line, open arrow, «creates»
    }

    struct Edge: Hashable {
        let from: String
        let to: String
        let kind: Kind
    }

    let boxes: [Box]
    let edges: [Edge]

    var rows: Int { (boxes.map(\.row).max() ?? 0) + 1 }
}

/// Short constructors so the decks stay readable
func box(_ id: String, _ col: Int, _ row: Int, _ members: [String] = [], interface: Bool = false, name: String? = nil) -> UMLDiagram.Box {
    UMLDiagram.Box(id: id, name: name ?? id, members: members, isInterface: interface, col: col, row: row)
}

func edge(_ from: String, _ kind: UMLDiagram.Kind, _ to: String) -> UMLDiagram.Edge {
    UMLDiagram.Edge(from: from, to: to, kind: kind)
}

struct UMLDiagramView: View {
    let diagram: UMLDiagram

    private let rowHeight: CGFloat = 112
    private let boxPadding: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width / 3
            let frames = Dictionary(uniqueKeysWithValues: diagram.boxes.map { ($0.id, frame(for: $0, colWidth: colWidth)) })

            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in diagram.edges {
                        guard let a = frames[e.from], let b = frames[e.to] else { continue }
                        draw(e.kind, from: a, to: b, in: &ctx)
                    }
                }

                ForEach(diagram.boxes, id: \.id) { b in
                    let f = frames[b.id]!
                    boxView(b)
                        .frame(width: f.width, height: f.height)
                        .position(x: f.midX, y: f.midY)
                }
            }
        }
        .frame(height: CGFloat(diagram.rows) * rowHeight)
    }

    private func frame(for b: UMLDiagram.Box, colWidth: CGFloat) -> CGRect {
        let height = 30 + CGFloat(b.members.count) * 14 + (b.isInterface ? 12 : 0)
        let width = colWidth - boxPadding * 2
        let x = CGFloat(b.col) * colWidth + boxPadding
        let y = CGFloat(b.row) * rowHeight + (rowHeight - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func boxView(_ b: UMLDiagram.Box) -> some View {
        VStack(spacing: 2) {
            if b.isInterface {
                Text("«interface»")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Text(b.name)
                .font(.system(size: 11, weight: .bold))
                .italic(b.isInterface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !b.members.isEmpty {
                Divider()
                ForEach(b.members, id: \.self) { m in
                    Text(m)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary, lineWidth: 1.2))
    }

    // MARK: - Edges

    /// Picks the facing sides of two boxes so lines don't cross through them
    private func endpoints(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint) {
        if abs(a.midY - b.midY) < 10 {
            return a.midX < b.midX
                ? (CGPoint(x: a.maxX, y: a.midY), CGPoint(x: b.minX, y: b.midY))
                : (CGPoint(x: a.minX, y: a.midY), CGPoint(x: b.maxX, y: b.midY))
        }
        return a.midY > b.midY
            ? (CGPoint(x: a.midX, y: a.minY), CGPoint(x: b.midX, y: b.maxY))
            : (CGPoint(x: a.midX, y: a.maxY), CGPoint(x: b.midX, y: b.minY))
    }

    private func draw(_ kind: UMLDiagram.Kind, from a: CGRect, to b: CGRect, in ctx: inout GraphicsContext) {
        let (start, end) = endpoints(a, b)
        let dashed = kind == .implements || kind == .creates
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        ctx.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 3] : []))

        let angle = atan2(end.y - start.y, end.x - start.x)
        func point(_ from: CGPoint, _ dist: CGFloat, _ off: CGFloat) -> CGPoint {
            CGPoint(x: from.x - dist * cos(angle + off), y: from.y - dist * sin(angle + off))
        }

        switch kind {
        case .inherits, .implements:
            var tri = Path()
            tri.move(to: end)
            tri.addLine(to: point(end, 11, 0.45))
            tri.addLine(to: point(end, 11, -0.45))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Color(.systemBackground)))
            ctx.stroke(tri, with: .color(.primary), lineWidth: 1.2)
        case .uses, .creates:
            var arrow = Path()
            arrow.move(to: point(end, 9, 0.5))
            arrow.addLine(to: end)
            arrow.addLine(to: point(end, 9, -0.5))
            ctx.stroke(arrow, with: .color(.primary), lineWidth: 1.2)
            if kind == .creates {
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                ctx.draw(Text("«creates»").font(.system(size: 7)).foregroundColor(.secondary), at: CGPoint(x: mid.x, y: mid.y - 7))
            }
        case .has, .hasMany:
            // Diamond at the owner's end
            let back = CGPoint(x: start.x + 14 * cos(angle), y: start.y + 14 * sin(angle))
            let side1 = CGPoint(x: start.x + 7 * cos(angle) + 5 * cos(angle + .pi / 2), y: start.y + 7 * sin(angle) + 5 * sin(angle + .pi / 2))
            let side2 = CGPoint(x: start.x + 7 * cos(angle) - 5 * cos(angle + .pi / 2), y: start.y + 7 * sin(angle) - 5 * sin(angle + .pi / 2))
            var diamond = Path()
            diamond.move(to: start)
            diamond.addLine(to: side1)
            diamond.addLine(to: back)
            diamond.addLine(to: side2)
            diamond.closeSubpath()
            ctx.fill(diamond, with: .color(Color(.systemBackground)))
            ctx.stroke(diamond, with: .color(.primary), lineWidth: 1.2)
            var arrow = Path()
            arrow.move(to: point(end, 8, 0.5))
            arrow.addLine(to: end)
            arrow.addLine(to: point(end, 8, -0.5))
            ctx.stroke(arrow, with: .color(.primary), lineWidth: 1.2)
            if kind == .hasMany {
                ctx.draw(Text("*").font(.system(size: 11, weight: .bold)), at: point(end, 12, 0.9))
            }
        }
    }
}
