import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(ExerciseStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(GymSession.self) private var gymSession
    @Query(sort: \WorkoutSession.date, order: .reverse) private var allSessions: [WorkoutSession]
    /// Finished or in-progress workouts with real sets (not an untouched Start)
    private var sessions: [WorkoutSession] { allSessions.filter(\.isLogged) }
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""
    /// Machines someone else is on right now (cleared when you switch gyms)
    @State private var taken: Set<String> = []
    @State private var skippedToday: Set<String> = []
    /// nil = automatic (split trained longest ago)
    @State private var splitChoice: String?

    private var currentGym: Gym? {
        gyms.first { $0.name == currentGymName }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    suggestionsSection
                    heatmapSection
                    recentSessionsSection
                }
                .padding()
            }
            .bentoScreen()
            .navigationTitle("da gym")
            .bentoCloseButton()
        }
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        // While a workout is going, keep showing its split; counting it as "trained" would flip Auto
        // to tomorrow's split mid-session
        let history = sessions.filter { $0 !== gymSession.active }
        let base = WorkoutEngine.suggestions(
            sessions: history,
            exerciseStore: store,
            gym: currentGym,
            split: gymSession.active.flatMap { WorkoutEngine.splitName(of: $0, store: store) } ?? splitChoice
        ).filter { !skippedToday.contains($0.exercise.id) }
        let suggestions = WorkoutEngine.applyingTaken(
            base,
            taken: taken,
            exerciseStore: store,
            gym: currentGym,
            sessions: history
        )

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Suggested")
                    .font(.headline)
                gymMenu
                Spacer()
                splitMenu(current: suggestions.first?.split)
            }

            if suggestions.isEmpty {
                Text("Nothing to suggest here yet. Mark what this gym has from an exercise's page.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(suggestions) { suggestion in
                            NavigationLink {
                                ExerciseDetailView(exercise: suggestion.exercise)
                            } label: {
                                SuggestionCard(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: suggestion) }
                        }
                    }
                    // Room for the cards' hard shadow
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                }
                Text("Long-press a card if a machine is taken or you're skipping it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    start(suggestions)
                } label: {
                    Label(gymSession.active == nil ? "Start \(suggestions.first?.split ?? "") workout" : "Resume workout",
                          systemImage: gymSession.active == nil ? "play.fill" : "arrow.right")
                }
                .buttonStyle(BentoButtonStyle())
            }
        }
    }

    /// Preloads today's suggestions (target weight × reps as planned sets) into Log
    private func start(_ suggestions: [WorkoutEngine.ExerciseSuggestion]) {
        defer { gymSession.tab = 1 }
        guard gymSession.active == nil else { return }

        let session = WorkoutSession(gymName: currentGym?.name)
        modelContext.insert(session)
        for (i, suggestion) in suggestions.enumerated() {
            let entry = WorkoutEntry(exerciseId: suggestion.exercise.id, order: i)
            session.entries.append(entry)
            let reps: [Int?] = suggestion.plan?.targetReps ?? [nil, nil, nil]
            entry.plannedCount = reps.count
            for (j, r) in reps.enumerated() {
                let set = WorkoutSet(order: j, weight: suggestion.plan?.weight, reps: r)
                set.isPlanned = true
                entry.sets.append(set)
            }
        }
        gymSession.active = session
    }

    /// Pick today's split; "Auto" follows whatever was trained longest ago
    private func splitMenu(current: String?) -> some View {
        Menu {
            Button {
                splitChoice = nil
            } label: {
                if splitChoice == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
            }
            Divider()
            ForEach(["Push", "Pull", "Legs"], id: \.self) { name in
                Button {
                    splitChoice = name
                } label: {
                    if splitChoice == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current ?? "Split")
                Image(systemName: "chevron.down").font(.caption2.bold())
            }
            .bentoPill()
        }
        .disabled(gymSession.active != nil)
    }

    private var gymMenu: some View {
        Menu {
            ForEach(gyms) { gym in
                Button {
                    currentGymName = gym.name
                    taken = []
                } label: {
                    if gym.name == currentGymName {
                        Label(gym.name, systemImage: "checkmark")
                    } else {
                        Text(gym.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                GymBadge(name: currentGym?.name, size: 14)
                Text(currentGym?.name ?? "Pick gym")
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func menu(for suggestion: WorkoutEngine.ExerciseSuggestion) -> some View {
        let id = suggestion.exercise.id
        if suggestion.kind != .later {
            Button {
                taken.insert(id)
            } label: {
                Label("Taken, swap it", systemImage: "arrow.triangle.2.circlepath")
            }
        } else {
            Button {
                taken.remove(id)
            } label: {
                Label("It's free now", systemImage: "arrow.uturn.up")
            }
        }
        Button {
            skippedToday.insert(id)
            taken.remove(id)
            CarryOver.add([id])
        } label: {
            Label("Skip today (do it first next time)", systemImage: "forward")
        }
        if let gym = currentGym {
            Divider()
            Button {
                gym.setStatus(.confirmed, for: id)
            } label: {
                Label("This is at \(gym.name)", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                gym.setStatus(.missing, for: id)
            } label: {
                Label("Not at \(gym.name)", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Text("\(sessions.count) workouts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HeatmapView(sessions: Array(sessions))
        }
        .padding(16)
        .bentoCard()
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)

            if sessions.isEmpty {
                Text("No workouts yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(sessions.prefix(10).enumerated()), id: \.element.id) { i, session in
                    if i > 0 { Divider() }
                    SessionRow(session: session, store: store)
                }
            }
        }
        .padding(16)
        .bentoCard()
    }
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: WorkoutEngine.ExerciseSuggestion

    private var noteColor: Color {
        switch suggestion.kind {
        case .carried: .orange
        case .substitute: .blue
        case .later: .secondary
        case .normal: .primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExerciseThumbnail(exercise: suggestion.exercise)
                .frame(height: 80)
                .frame(maxWidth: .infinity)

            Text(suggestion.exercise.name)
                .font(.subheadline.bold())
                .lineLimit(2)

            if let plan = suggestion.plan {
                Text("\(plan.weight.clean) lb × \(plan.targetReps.map(String.init).joined(separator: "/"))")
                    .font(.caption.monospacedDigit())
                Text("last \(plan.lastWeight.clean) × \(plan.lastReps.map(String.init).joined(separator: "/"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let note = suggestion.note {
                Text(note)
                    .font(.caption2.bold())
                    .foregroundStyle(noteColor)
                    .lineLimit(2)
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(12)
        .bentoCard(cornerRadius: 18)
        .opacity(suggestion.kind == .later ? 0.6 : 1)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: WorkoutSession
    let store: ExerciseStore

    private var exerciseNames: String {
        session.sortedEntries
            .compactMap { store.exercise(id: $0.exerciseId)?.name }
            .prefix(3)
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.date, format: .dateTime.month(.abbreviated).day())
                    .font(.subheadline.bold())
                if let gym = session.gymName {
                    Text("@ \(gym)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(session.entries.count) exercises")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(exerciseNames)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Heatmap

struct HeatmapView: View {
    let sessions: [WorkoutSession]
    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    private var days: [WorkoutEngine.HeatmapDay] {
        WorkoutEngine.heatmapData(sessions: sessions, weeks: 52)
    }

    /// Columns of 7 days, Sunday at the top, so each row is a weekday like GitHub's chart
    private var weeks: [[WorkoutEngine.HeatmapDay]] {
        let calendar = Calendar.current
        let all = days
        let leading = all.first.map { calendar.component(.weekday, from: $0.date) - 1 } ?? 0
        let trimmed = Array(all.dropFirst((7 - leading) % 7))
        return stride(from: 0, to: trimmed.count, by: 7).map {
            Array(trimmed[$0..<min($0 + 7, trimmed.count)])
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { weekIdx, week in
                        VStack(alignment: .leading, spacing: spacing) {
                            // Month label on the week a month starts, like GitHub
                            Text(monthLabel(week, index: weekIdx))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cellSize, height: 11, alignment: .leading)
                            ForEach(week) { day in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colorForIntensity(day.intensity))
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                        .id(weekIdx)
                    }
                }
                .padding(.vertical, 4)
                .onAppear {
                    if let lastIdx = weeks.indices.last {
                        proxy.scrollTo(lastIdx, anchor: .trailing)
                    }
                }
            }
        }
        .frame(height: 7 * (cellSize + spacing) + 14)

        // Legend
        HStack(spacing: 4) {
            Spacer()
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForIntensity(i))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func monthLabel(_ week: [WorkoutEngine.HeatmapDay], index: Int) -> String {
        guard let first = week.first else { return "" }
        let cal = Calendar.current
        let startsMonth = index == 0 || week.contains { cal.component(.day, from: $0.date) == 1 }
        guard startsMonth, let day = index == 0 ? first.date : week.first(where: { cal.component(.day, from: $0.date) == 1 })?.date else { return "" }
        return day.formatted(.dateTime.month(.abbreviated))
    }

    private func colorForIntensity(_ level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.06)
        case 1: return Color.bentoActivity.opacity(0.35)
        case 2: return Color.bentoActivity.opacity(0.55)
        case 3: return Color.bentoActivity.opacity(0.8)
        default: return Color.bentoActivity
        }
    }
}
