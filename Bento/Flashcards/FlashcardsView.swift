import SwiftUI

struct FlashcardsView: View {
    private let progress = StudyProgress.shared
    private let store = DeckStore.shared
    @State private var reel: [Flashcard]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Button {
                        reel = []
                    } label: {
                        Label("Scroll the reel", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    }
                    .buttonStyle(BentoButtonStyle())

                    if store.decks.isEmpty {
                        VStack(spacing: 8) {
                            if store.isRefreshing { ProgressView() }
                            Text(store.problem ?? (store.isRefreshing ? "Loading decks from Notion…" : "No decks yet. Add some in Notion › Bento › Decks."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    } else if let problem = store.problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.decks) { deck in
                        NavigationLink(value: deck.id) {
                            DeckCard(deck: deck, summary: StudyProgress.summary(due: progress.reviewsDue(in: deck), new: progress.newCount(in: deck)),
                                     mastery: progress.mastery(of: deck))
                        }
                        .buttonStyle(BentoPressStyle())
                    }
                }
                .padding(20)
            }
            .background(Color.bentoPaper.ignoresSafeArea())
            .navigationTitle("flashcards")
            .fullScreenCover(isPresented: Binding(get: { reel != nil }, set: { if !$0 { reel = nil } })) {
                ReelView(title: "All decks", decks: store.decks)
            }
            .bentoCloseButton()
            .navigationDestination(for: String.self) { id in
                if let deck = store.decks.first(where: { $0.id == id }) {
                    DeckView(deck: deck)
                }
            }
        }
        .fontDesign(.rounded)
        .task { await store.refreshIfStale() }
        .refreshable { await store.refresh() }
    }
}

private struct DeckCard: View {
    let deck: Deck
    let summary: String
    let mastery: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: deck.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
                Spacer()
                Text(summary)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
            }
            Text(deck.title)
                .font(.title3.bold())
            Text("\(deck.subtitle) · \(deck.cards.count) cards")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: mastery)
                .tint(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bentoCard()
    }
}

// MARK: - Deck

struct DeckView: View {
    let deck: Deck
    @State private var studying = false
    @State private var reeling = false
    @State private var assembling: [AssembleQuiz]?
    @State private var drawingUML = false
    private let progress = StudyProgress.shared

    var body: some View {
        List {
            Section {
                Button {
                    studying = true
                } label: {
                    Label("Study \(progress.due(in: deck).count) cards", systemImage: "play.fill")
                }
                .buttonStyle(BentoButtonStyle())
                .disabled(progress.due(in: deck).isEmpty)
                .listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 6, trailing: 4))
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    reeling = true
                } label: {
                    Label("Reel", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                }
                if !deck.quizzes.isEmpty {
                    Button {
                        assembling = deck.quizzes.shuffled()
                    } label: {
                        Label("Build the equations", systemImage: "puzzlepiece")
                    }
                }
                if !deck.uml.isEmpty {
                    Button {
                        drawingUML = true
                    } label: {
                        Label("Draw the UML", systemImage: "rectangle.connected.to.line.below")
                    }
                }
                if !deck.ladder.isEmpty {
                    NavigationLink {
                        UnitLadderView(quantities: deck.ladder)
                    } label: {
                        Label("Unit ladder", systemImage: "stairs")
                    }
                }
            }

            Section("All cards") {
                ForEach(deck.cards) { card in
                    NavigationLink {
                        ScrollView {
                            CardFace(card: card, showBack: true)
                                .padding(20)
                                .bentoCard()
                                .padding()
                        }
                        .bentoScreen()
                    } label: {
                        HStack {
                            Text(TeXPlain.convert(card.front.components(separatedBy: "\n").first ?? card.front))
                                .lineLimit(2)
                            Spacer()
                            BoxDots(box: progress.box(of: card))
                        }
                    }
                }
            }

            Section {
                Button("Reset progress", role: .destructive) { progress.reset(deck) }
            }
        }
        .bentoScreen()
        .navigationTitle(deck.title)
        .fullScreenCover(isPresented: $studying) {
            StudySession(deck: deck)
        }
        .fullScreenCover(isPresented: Binding(get: { assembling != nil }, set: { if !$0 { assembling = nil } })) {
            AssembleSession(title: deck.title, quizzes: assembling ?? [])
        }
        .fullScreenCover(isPresented: $drawingUML) {
            UMLSession(quizzes: deck.uml.shuffled())
        }
        .fullScreenCover(isPresented: $reeling) {
            ReelView(title: deck.title, decks: [deck])
        }
    }
}

private struct BoxDots: View {
    let box: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(i < box ? Color.primary : Color.primary.opacity(0.12))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Study

struct StudySession: View {
    let deck: Deck
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Flashcard] = []
    @State private var flipped = false
    /// An interactive card has been answered (it records itself)
    @State private var answered = false
    @State private var right = 0
    @State private var total = 0
    private let progress = StudyProgress.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let card = queue.first {
                    ScrollView {
                        CardFace(card: card, showBack: card.isInteractive ? false : flipped) { correct in
                            progress.record(card, correct: correct)
                            total += 1
                            if correct { right += 1 }
                            answered = true
                        }
                            .padding(20)
                            .frame(maxWidth: .infinity, minHeight: 360)
                            .bentoCard()
                            .padding(.horizontal, 4)
                            .onTapGesture {
                                guard !card.isInteractive else { return }
                                withAnimation(.snappy) { flipped.toggle() }
                            }
                            .id(card.id)
                    }

                    if card.isInteractive {
                        if answered {
                            Button("Next") {
                                answered = false
                                queue.removeFirst()
                            }
                            .buttonStyle(BentoButtonStyle())
                        } else {
                            Text("Answer on the card")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(height: 52)
                        }
                    } else if flipped {
                        HStack(spacing: 14) {
                            answerButton("Missed", symbol: "xmark", correct: false, card: card)
                            answerButton("Got it", symbol: "checkmark", correct: true, card: card)
                        }
                    } else {
                        Text("Tap the card to flip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 52)
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 56))
                    Text(total == 0 ? "Nothing due" : "\(right)/\(total) right")
                        .font(.title.bold())
                    Text("Missed cards come back in 10 minutes; the rest when they're due.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            }
            .padding()
            .background(Color.bentoPaper.ignoresSafeArea())
            .navigationTitle(queue.isEmpty ? deck.title : "\(queue.count) left")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fontDesign(.rounded)
        .onAppear { queue = progress.due(in: deck) }
    }

    private func answerButton(_ title: String, symbol: String, correct: Bool, card: Flashcard) -> some View {
        Button {
            progress.record(card, correct: correct)
            total += 1
            if correct { right += 1 }
            flipped = false
            queue.removeFirst()
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .bentoCard(cornerRadius: 16)
        }
        .buttonStyle(BentoPressStyle())
    }
}

/// Front, or front + back (with diagram) once flipped
struct CardFace: View {
    let card: Flashcard
    let showBack: Bool
    /// Interactive cards report whether you got them right
    var onResult: ((Bool) -> Void)? = nil

    @State private var engineHeight: CGFloat = 200

    var body: some View {
        if card.isInteractive, let payload = card.payload {
            VStack(alignment: .leading, spacing: 10) {
                if let tag = card.tag {
                    Text(tag.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                // Interactive cards are answered, not flipped: showBack means "show it solved"
                CardEngine(payload: payload, reveal: showBack, height: $engineHeight) { onResult?($0) }
                    .frame(height: engineHeight)
                    .id(card.id + (showBack ? "-solved" : ""))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            flipFace
        }
    }

    private var flipFace: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tag = card.tag {
                Text(tag.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            MathText(card.front, size: 22, bold: true)

            if showBack {
                Divider()
                MathText(card.back, size: 17)
                if let diagram = card.diagram {
                    UMLDiagramView(diagram: diagram)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// MARK: - Unit ladder

/// Every quantity as "A × B = C", grouped, so you can see how units build on each other
struct UnitLadderView: View {
    let quantities: [UnitQuantity]

    private var groups: [(String, [UnitQuantity])] {
        var order: [String] = []
        for q in quantities where !order.contains(q.group) { order.append(q.group) }
        return order.map { g in (g, quantities.filter { $0.group == g }) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { q in
                        VStack(alignment: .leading, spacing: 4) {
                            if let (l, op, r) = q.built {
                                HStack(spacing: 6) {
                                    chip(l)
                                    Text(op).font(.headline)
                                    chip(r)
                                    Text("=").font(.headline)
                                    chip(q.name, bold: true)
                                }
                            }
                            MathText("$\(q.formula)$   ·   $\(q.unit) = \(q.expanded)$", size: 15)
                            if let note = q.note {
                                MathText(note, size: 13)
                                    .opacity(0.65)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .bentoScreen()
        .navigationTitle("Unit ladder")
    }

    private func chip(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(bold ? .bold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(bold ? Color.primary : Color.clear, in: Capsule())
            .foregroundStyle(bold ? Color(.systemBackground) : .primary)
            .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
    }
}
