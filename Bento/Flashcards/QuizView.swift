import SwiftUI

// MARK: - Assemble the equation

struct AssembleSession: View {
    let title: String
    let quizzes: [AssembleQuiz]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var solved = 0

    var body: some View {
        NavigationStack {
            Group {
                if index < quizzes.count {
                    AssembleCard(quiz: quizzes[index]) { correct in
                        if correct { solved += 1 }
                        withAnimation(.snappy) { index += 1 }
                    }
                    .id(quizzes[index].id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal").font(.system(size: 56))
                        Text("\(solved)/\(quizzes.count) on the first try").font(.title2.bold())
                        Button("Again") {
                            solved = 0
                            index = 0
                        }
                        .buttonStyle(BentoButtonStyle())
                        .frame(width: 200)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.bentoPaper.ignoresSafeArea())
            .navigationTitle(index < quizzes.count ? "\(index + 1) of \(quizzes.count)" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .fontDesign(.rounded)
    }
}

private struct AssembleCard: View {
    let quiz: AssembleQuiz
    /// Called with whether it was right on the first check
    let next: (Bool) -> Void

    @State private var bank: [TileKind] = []
    @State private var rootSeq = EditSeq()
    /// Which slot new tiles go into
    @State private var selected: UUID?
    /// A placed piece picked for removal
    @State private var selectedNode: UUID?
    /// node id -> bank index it came from
    @State private var usedBy: [UUID: Int] = [:]
    /// Bumped on every edit so SwiftUI re-renders the class-based tree
    @State private var version = 0
    @State private var verdict: Bool?
    @State private var firstTry: Bool?
    @State private var revealed = false
    @State private var boardHeight: CGFloat = 220
    @State private var info: String?
    @State private var showGlossary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MathText(quiz.prompt, size: 20, bold: true)

                if !quiz.glossary.isEmpty {
                    DisclosureGroup(isExpanded: $showGlossary) {
                        MathText(quiz.glossary.map { "$\($0.0)$: \($0.1)" }.joined(separator: "\n"), size: 15)
                            .padding(.top, 6)
                    } label: {
                        Label("What's what", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.primary)
                }

                ExprBoard(
                    expression: displayTeX(),
                    tiles: bank.indices.map { ExprBoard.Tile(tex: bank[$0].labelTeX, enabled: !usedBy.values.contains($0)) },
                    verdict: verdict.map { $0 ? "right" : "wrong" },
                    height: $boardHeight,
                    onEvent: handle
                )
                .frame(height: boardHeight)
                .id(quiz.id)

                if let info {
                    MathText(info, size: 15)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .bentoCard(cornerRadius: 14)
                        .onTapGesture { self.info = nil }
                }

                HStack(spacing: 10) {
                    Button { stepOut() } label: { Label("Step out", systemImage: "arrow.up.left") }
                        .buttonStyle(BentoButtonStyle(prominent: false))
                        .disabled(currentSeq?.parent == nil)
                    Button { removeSelected() } label: { Label("Remove", systemImage: "delete.left") }
                        .buttonStyle(BentoButtonStyle(prominent: false))
                        .disabled(selectedNode == nil)
                    Button { clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(BentoButtonStyle(prominent: false))
                        .frame(width: 64)
                        .disabled(rootSeq.nodes.isEmpty)
                }

                feedback

                HStack(spacing: 12) {
                    if verdict == true || revealed {
                        Button("Next") { next(firstTry ?? false) }
                            .buttonStyle(BentoButtonStyle())
                    } else {
                        Button("Show answer") {
                            revealed = true
                            if firstTry == nil { firstTry = false }
                        }
                        .buttonStyle(BentoButtonStyle(prominent: false))
                        Button("Check") { check() }
                            .buttonStyle(BentoButtonStyle())
                            .disabled(rootSeq.nodes.isEmpty)
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            bank = quiz.tiles.shuffled()
            selected = rootSeq.id
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if verdict == true {
            VStack(alignment: .leading, spacing: 6) {
                Label("Correct", systemImage: "checkmark.circle.fill").font(.headline)
                if !quiz.explain.isEmpty { MathText(quiz.explain, size: 15) }
            }
        } else if verdict == false {
            Label("Not quite. Check the order and what's inside each box.", systemImage: "xmark.circle")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        if revealed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Answer").font(.caption.bold()).foregroundStyle(.secondary)
                MathText("$$" + Expr.tex(quiz.answer) + "$$", size: 18)
                if !quiz.explain.isEmpty { MathText(quiz.explain, size: 15) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bentoCard(cornerRadius: 16)
        }
    }

    // MARK: Tree

    private var currentSeq: EditSeq? { selected.flatMap(findSeq) }

    private func findSeq(_ id: UUID) -> EditSeq? {
        func walk(_ seq: EditSeq) -> EditSeq? {
            if seq.id == id { return seq }
            for node in seq.nodes { for arg in node.args { if let hit = walk(arg) { return hit } } }
            return nil
        }
        return walk(rootSeq)
    }

    private func findNode(_ id: UUID) -> EditNode? {
        func walk(_ seq: EditSeq) -> EditNode? {
            for node in seq.nodes {
                if node.id == id { return node }
                for arg in node.args { if let hit = walk(arg) { return hit } }
            }
            return nil
        }
        return walk(rootSeq)
    }

    /// TeX with clickable ids: empty/selected slots are boxes, every node is tappable
    private func displayTeX() -> String {
        _ = version
        func seqTeX(_ seq: EditSeq) -> String {
            var parts = seq.nodes.map { node -> String in
                let inner: String
                switch node.kind {
                case .atom(let t): inner = t
                case .fn(let tpl): inner = tpl.render(node.args.map { "{" + seqTeX($0) + "}" })
                }
                let tagged = #"\htmlId{n-\#(node.id.uuidString)}{\#(inner)}"#
                return node.id == selectedNode ? #"\htmlClass{selnode}{\#(tagged)}"# : tagged
            }
            let isSelected = seq.id == selected && verdict != true
            if isSelected {
                parts.append(#"\htmlId{s-\#(seq.id.uuidString)}{\color{#2f7bf6}{\boxed{\vphantom{X}\hspace{0.9em}}}}"#)
            } else if seq.nodes.isEmpty {
                parts.append(#"\htmlId{s-\#(seq.id.uuidString)}{\color{#999999}{\boxed{\vphantom{X}\hspace{0.9em}}}}"#)
            }
            return parts.joined(separator: " ")
        }
        return seqTeX(rootSeq)
    }

    private func handle(_ event: ExprBoard.Event) {
        switch event {
        case .tile(let i):
            selectedNode = nil
            guard let seq = currentSeq ?? Optional(rootSeq), !usedBy.values.contains(i) else { return }
            let node = EditNode(bank[i], owner: seq)
            seq.nodes.append(node)
            usedBy[node.id] = i
            // A function's first slot becomes the target, so the next tap fills it
            if let first = node.args.first { selected = first.id }
            edited()
        case .info(let i):
            info = quiz.meaning(of: bank[i]).map { "$\(bank[i].labelTeX)$: \($0)" }
                ?? "$\(bank[i].labelTeX)$: no hint for this one. It might be a decoy."
        case .slot(let id):
            selectedNode = nil
            selected = UUID(uuidString: id) ?? rootSeq.id
            version += 1
        case .node(let id):
            // Select it (Remove deletes); new tiles go after it in the same box
            guard let uuid = UUID(uuidString: id), let node = findNode(uuid), let owner = node.owner else { return }
            selectedNode = selectedNode == uuid ? nil : uuid
            selected = owner.id
            version += 1
        case .background:
            selectedNode = nil
            selected = rootSeq.id
            version += 1
        }
    }

    private func free(_ node: EditNode) {
        usedBy[node.id] = nil
        node.args.flatMap(\.nodes).forEach(free)
    }

    private func removeSelected() {
        guard let id = selectedNode, let node = findNode(id), let owner = node.owner else { return }
        owner.nodes.removeAll { $0 === node }
        free(node)
        selectedNode = nil
        selected = owner.id
        edited()
    }

    private func stepOut() {
        guard let seq = currentSeq, let parentNode = seq.parent, let owner = parentNode.owner else { return }
        selected = owner.id
        version += 1
    }

    private func clear() {
        selectedNode = nil
        rootSeq = EditSeq()
        usedBy = [:]
        selected = rootSeq.id
        edited()
    }

    private func edited() {
        verdict = nil
        version += 1
    }

    private func check() {
        let ok = quiz.isCorrect(rootSeq.expr)
        verdict = ok
        if firstTry == nil { firstTry = ok }
    }
}

// MARK: - UML

struct UMLSession: View {
    let quizzes: [UMLQuiz]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        NavigationStack {
            Group {
                if index < quizzes.count {
                    UMLCard(quiz: quizzes[index]) { withAnimation(.snappy) { index += 1 } }
                        .id(quizzes[index].id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal").font(.system(size: 56))
                        Text("All diagrams done").font(.title2.bold())
                        Button("Again") { index = 0 }
                            .buttonStyle(BentoButtonStyle())
                            .frame(width: 200)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.bentoPaper.ignoresSafeArea())
            .navigationTitle(index < quizzes.count ? quizzes[index].name : "UML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .fontDesign(.rounded)
    }
}

private struct UMLCard: View {
    let quiz: UMLQuiz
    let next: () -> Void

    @State private var answers: [Int: UMLDiagram.Kind?] = [:]
    @State private var checked = false

    private static let options: [(String, UMLDiagram.Kind?)] = [
        ("inherits ▷", .inherits), ("implements ▷ (dashed)", .implements),
        ("has ◇", .has), ("has many ◇*", .hasMany),
        ("uses →", .uses), ("creates ⇢", .creates), ("no arrow", nil),
    ]

    private var questions: [(from: String, to: String, answer: UMLDiagram.Kind?)] { quiz.questions }

    private var score: Int {
        questions.indices.filter { answers[$0] == .some(questions[$0].answer) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(quiz.intent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                UMLDiagramView(diagram: checked ? quiz.diagram : UMLDiagram(boxes: quiz.diagram.boxes, edges: []))
                    .padding(12)
                    .bentoCard(cornerRadius: 20)

                Text(checked ? "\(score)/\(questions.count) right" : "Draw the arrows")
                    .font(.headline)

                ForEach(questions.indices, id: \.self) { i in
                    let q = questions[i]
                    HStack {
                        Text("\(q.from) → \(q.to)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        Menu {
                            ForEach(Self.options, id: \.0) { option in
                                Button(option.0) { answers[i] = .some(option.1) }
                            }
                        } label: {
                            Text(label(for: answers[i]))
                                .font(.subheadline)
                                .bentoPill()
                        }
                        .disabled(checked)
                        if checked {
                            Image(systemName: answers[i] == .some(q.answer) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(answers[i] == .some(q.answer) ? Color.bentoActivity : .red)
                        }
                    }
                    if checked, answers[i] != .some(q.answer) {
                        Text("Answer: \(label(for: .some(q.answer)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(checked ? "Next" : "Check") {
                    if checked { next() } else { checked = true }
                }
                .buttonStyle(BentoButtonStyle())
                .disabled(!checked && answers.count < questions.count)
            }
            .padding(20)
        }
    }

    private func label(for answer: UMLDiagram.Kind??) -> String {
        guard let answer else { return "choose" }
        return Self.options.first { $0.1 == answer }?.0 ?? "choose"
    }
}

// MARK: - Flow layout

/// Wraps tiles onto new lines
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
