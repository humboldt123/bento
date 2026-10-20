import SwiftUI

/// Full-screen vertical feed of cards. Two modes:
/// - Learn: question and answer together, new cards first, nothing graded (just read)
/// - Study: tap to flip, ✗ / ✓ to grade, due cards first
struct ReelView: View {
    enum Mode: String, CaseIterable { case learn = "Learn", study = "Study" }

    let title: String
    let decks: [Deck]

    @AppStorage("reelMode") private var mode: Mode = .study
    /// Shared with the deck screen's Shuffle toggle
    @AppStorage("shuffleCards") private var shuffle = false
    @State private var cards: [Flashcard] = []

    @Environment(\.dismiss) private var dismiss
    @State private var flipped: Set<String> = []
    @State private var graded: [String: Bool] = [:]
    @State private var current: String?
    private let progress = StudyProgress.shared

    /// Study: due first. Learn: cards you've never seen first (in deck order, so topics build up,
    /// unless shuffle is on).
    static func feed(from decks: [Deck], mode: Mode, shuffle: Bool = false) -> [Flashcard] {
        let progress = StudyProgress.shared
        let all = decks.flatMap(\.cards)
        switch mode {
        case .study:
            return all.filter { progress.isDue($0) }.shuffled() + all.filter { !progress.isDue($0) }.shuffled()
        case .learn:
            let new = all.filter(progress.isNew), seen = all.filter { !progress.isNew($0) }
            return shuffle ? new.shuffled() + seen.shuffled() : new + seen
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(cards) { card in
                    page(card)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(card.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .background(Color.bentoPaper.ignoresSafeArea())
        .ignoresSafeArea()
        .overlay(alignment: .top) { header }
        .fontDesign(.rounded)
        .onAppear { reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onChange(of: shuffle) { _, _ in reload() }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .bentoCard(cornerRadius: 20)
            }
            .buttonStyle(BentoPressStyle())
            Spacer()
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Spacer()
            let done = graded.values.count
            let right = graded.values.filter { $0 }.count
            Button {
                shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.subheadline.bold())
                    .foregroundStyle(shuffle ? Color.primary : Color.secondary.opacity(0.5))
            }
            .accessibilityLabel(shuffle ? "Shuffle on" : "Shuffle off")
            Text("\(right)/\(done)")
                .font(.subheadline.monospacedDigit().bold())
                .frame(minWidth: 40)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func reload() {
        cards = Self.feed(from: decks, mode: mode, shuffle: shuffle)
        flipped = []
        current = cards.first?.id
    }

    private func page(_ card: Flashcard) -> some View {
        let isFlipped = mode == .learn || flipped.contains(card.id)
        return VStack(spacing: 18) {
            Spacer(minLength: 110)

            ScrollView {
                CardFace(card: card, showBack: card.isInteractive ? mode == .learn : isFlipped) { correct in
                    progress.record(card, correct: correct)
                    graded[card.id] = correct
                }
                .padding(22)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .bentoCard(cornerRadius: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                guard mode == .study, !card.isInteractive else { return }
                withAnimation(.snappy) {
                    if isFlipped { flipped.remove(card.id) } else { flipped.insert(card.id) }
                }
            }

            if mode == .learn {
                Text("\(title) · swipe up for the next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 54)
            } else if card.isInteractive {
                Text(graded[card.id].map { $0 ? "✓ got it · swipe up for next" : "✗ read why · swipe up for next" } ?? "answer on the card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 54)
            } else if isFlipped {
                HStack(spacing: 14) {
                    grade(card, correct: false)
                    grade(card, correct: true)
                }
            } else {
                Text(graded[card.id].map { $0 ? "✓ got it" : "✗ missed" } ?? "tap to flip · swipe up for next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 54)
            }

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 20)
    }

    private func grade(_ card: Flashcard, correct: Bool) -> some View {
        Button {
            progress.record(card, correct: correct)
            graded[card.id] = correct
            flipped.remove(card.id)
            // Jump to the next card
            if let i = cards.firstIndex(of: card), i + 1 < cards.count {
                withAnimation(.snappy) { current = cards[i + 1].id }
            }
        } label: {
            Label(correct ? "Got it" : "Missed", systemImage: correct ? "checkmark" : "xmark")
        }
        .buttonStyle(BentoButtonStyle(prominent: correct))
    }
}
