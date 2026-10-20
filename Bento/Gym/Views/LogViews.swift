import SwiftUI
import SwiftData

/// Log: add exercise → pick weight/reps → add set → repeat
struct ActiveSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ExerciseStore.self) private var store
    @Environment(GymSession.self) private var gymSession
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @Query private var allSessions: [WorkoutSession]
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""

    @State private var showExerciseSearch = false
    /// "No other machine for that" etc.
    @State private var swapMessage: String?
    /// Picked in search; opened once the search sheet is gone
    @State private var pendingEntry: WorkoutEntry?
    @State private var editingEntry: WorkoutEntry?

    private var session: WorkoutSession? { gymSession.active }

    var body: some View {
        NavigationStack {
            List {
                if let session {
                    Section {
                        ForEach(session.sortedEntries) { entry in
                            Button {
                                editingEntry = entry
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { entryMenu(entry, in: session) }
                            .swipeActions(edge: .leading) {
                                Button { swap(entry, in: session) } label: { Label("Taken", systemImage: "arrow.triangle.2.circlepath") }
                                    .tint(.orange)
                                Button { moveToEnd(entry, in: session) } label: { Label("Later", systemImage: "clock") }
                                    .tint(.blue)
                            }
                        }
                        .onDelete { offsets in
                            let entries = session.sortedEntries
                            for i in offsets {
                                session.entries.removeAll { $0 === entries[i] }
                                modelContext.delete(entries[i])
                            }
                        }
                    } header: {
                        gymMenu(session)
                    } footer: {
                        Text(swapMessage ?? "Machine taken? Swipe right on an exercise or hold it to swap, try later or skip.")
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        showExerciseSearch = true
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                    }
                    .buttonStyle(BentoButtonStyle())
                    .listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 6, trailing: 4))
                    .listRowBackground(Color.clear)
                }

                if let session, session.entries.contains(where: { $0.sets.contains { !$0.isPlanned } }) {
                    Section {
                        Button("Finish workout") { finish() }
                            .buttonStyle(BentoButtonStyle(prominent: false))
                            .listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 6, trailing: 4))
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .bentoScreen()
            .navigationTitle(session == nil ? "Log" : session!.date.formatted(.dateTime.weekday(.wide)))
            .bentoCloseButton()
            .sheet(isPresented: $showExerciseSearch, onDismiss: {
                editingEntry = pendingEntry
                pendingEntry = nil
            }) {
                ExerciseSearchView { exercise in
                    pendingEntry = add(exercise)
                }
            }
            .sheet(item: $editingEntry) { entry in
                SetEntrySheet(entry: entry)
            }
        }
    }

    // MARK: Taken / later / skip

    private var gym: Gym? { gyms.first { $0.name == (session?.gymName ?? currentGymName) } }

    @ViewBuilder
    private func entryMenu(_ entry: WorkoutEntry, in session: WorkoutSession) -> some View {
        Button { swap(entry, in: session) } label: {
            Label("Taken, swap it", systemImage: "arrow.triangle.2.circlepath")
        }
        Button { moveToEnd(entry, in: session) } label: {
            Label("Try later", systemImage: "clock")
        }
        Button { skip(entry, in: session) } label: {
            Label("Skip today (do it first next time)", systemImage: "forward")
        }
    }

    /// Puts a substitute (same muscles, available here) right after the taken exercise, with its
    /// own planned sets, and moves the taken one to the end to try later
    private func swap(_ entry: WorkoutEntry, in session: WorkoutSession) {
        guard let ex = store.exercise(id: entry.exerciseId) else { return }
        let history = allSessions.filter { $0 !== session }
        guard let sub = WorkoutEngine.substitute(for: ex, excluding: Set(session.exerciseIds),
                                                 exerciseStore: store, gym: gym, sessions: history) else {
            swapMessage = "No substitute for \(ex.name) here. Moved it to the end."
            moveToEnd(entry, in: session)
            return
        }
        for e in session.entries where e.order > entry.order { e.order += 1 }
        let new = WorkoutEntry(exerciseId: sub.id, order: entry.order + 1)
        let (plan, _) = WorkoutEngine.plan(for: sub, gym: gym, sessions: history)
        let reps: [Int?] = plan?.targetReps ?? [nil, nil, nil]
        for (j, r) in reps.enumerated() {
            let set = WorkoutSet(order: j, weight: plan?.weight, reps: r)
            set.isPlanned = true
            new.sets.append(set)
        }
        session.entries.append(new)
        if !entry.sets.contains(where: { !$0.isPlanned }) { moveToEnd(entry, in: session) }
        swapMessage = "\(sub.name) instead of \(ex.name). \(ex.name) moved to the end."
    }

    private func moveToEnd(_ entry: WorkoutEntry, in session: WorkoutSession) {
        entry.order = (session.entries.map(\.order).max() ?? 0) + 1
    }

    /// Drops it from today (if nothing logged) and puts it first next time
    private func skip(_ entry: WorkoutEntry, in session: WorkoutSession) {
        CarryOver.add([entry.exerciseId])
        if !entry.sets.contains(where: { !$0.isPlanned }) {
            session.entries.removeAll { $0 === entry }
            modelContext.delete(entry)
        }
        swapMessage = "Skipped. It'll be first next time."
    }

    private func gymMenu(_ session: WorkoutSession) -> some View {
        Menu {
            ForEach(gyms) { gym in
                Button(gym.name) {
                    session.gymName = gym.name
                    currentGymName = gym.name
                }
            }
        } label: {
            HStack(spacing: 6) {
                GymBadge(name: session.gymName, size: 14)
                Text(session.gymName ?? "Pick gym")
            }
            .font(.caption)
        }
        .textCase(nil)
    }

    private func add(_ exercise: ExerciseDefinition) -> WorkoutEntry {
        let session = self.session ?? {
            let new = WorkoutSession(gymName: currentGymName.isEmpty ? nil : currentGymName)
            modelContext.insert(new)
            gymSession.active = new
            return new
        }()
        if let existing = session.entries.first(where: { $0.exerciseId == exercise.id }) {
            return existing
        }
        let entry = WorkoutEntry(exerciseId: exercise.id, order: session.entries.count)
        session.entries.append(entry)
        return entry
    }

    /// Drops planned (never done) sets and empty exercises, then closes the session
    private func finish() {
        guard let session else { return }
        for entry in session.entries {
            for set in entry.sets where set.isPlanned || (set.weight == nil && set.reps == nil) {
                entry.sets.removeAll { $0 === set }
                modelContext.delete(set)
            }
            if entry.sets.isEmpty {
                session.entries.removeAll { $0 === entry }
                modelContext.delete(entry)
            }
        }
        if session.entries.isEmpty {
            modelContext.delete(session)
        }
        gymSession.active = nil
    }
}

// MARK: - Entry Row

private struct EntryRow: View {
    let entry: WorkoutEntry
    @Environment(ExerciseStore.self) private var store

    var body: some View {
        let done = entry.sortedSets.filter { !$0.isPlanned }
        let planned = entry.sets.count - done.count
        HStack(spacing: 12) {
            if let ex = store.exercise(id: entry.exerciseId) {
                ExerciseThumbnail(exercise: ex)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.exercise(id: entry.exerciseId)?.name ?? "Exercise")
                    .font(.headline)
                if done.isEmpty {
                    Text(planned > 0 ? "\(planned) sets planned" : "tap to add sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(done.map { "\(($0.weight ?? 0).clean)×\($0.reps ?? 0)" }.joined(separator: "  "))
                        .font(.subheadline.monospacedDigit())
                    + Text(planned > 0 ? "  · \(planned) to go" : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Set Entry

/// Pick weight and reps, tap Add set, repeat
struct SetEntrySheet: View {
    @Bindable var entry: WorkoutEntry
    @Environment(ExerciseStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [WorkoutSession]
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""

    @State private var weight: Double = 0
    @State private var reps = 10
    /// "Guess: ~80% of SIG (85 lb)" when there's no history at this gym
    @State private var guessNote: String?
    /// Suggested next weight after a set that hit the top of the rep range
    @State private var nudge: Double?

    private var exercise: ExerciseDefinition? { store.exercise(id: entry.exerciseId) }
    private var gym: Gym? { gyms.first { $0.name == (entry.session?.gymName ?? currentGymName) } }
    private var done: [WorkoutSet] { entry.sortedSets.filter { !$0.isPlanned } }
    private var planned: [WorkoutSet] { entry.sortedSets.filter(\.isPlanned) }

    private var step: Double {
        guard let exercise else { return 5 }
        return WorkoutEngine.weightStep(for: exercise, gym: gym, sessions: sessions)
    }

    /// "last time 70×12, 85×11" from previous sessions (not this one)
    private var lastTime: String? {
        guard let exercise else { return nil }
        let others = sessions.filter { $0 !== entry.session }
        guard let last = WorkoutEngine.lastPerformance(of: exercise, gym: gym, sessions: others) else { return nil }
        return "last time " + last.sets.map { "\(($0.weight ?? 0).clean)×\($0.reps ?? 0)" }.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let lastTime {
                    Text(lastTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let guessNote {
                    Label(guessNote, systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                VStack(spacing: 14) {
                    stepper(value: Binding(get: { weight }, set: { weight = max(0, $0) }),
                            step: step, unit: "lb", format: { $0.clean })
                    stepper(value: Binding(get: { Double(reps) }, set: { reps = max(1, Int($0)) }),
                            step: 1, unit: "reps", format: { String(Int($0)) })
                }

                Button {
                    addSet()
                } label: {
                    Text(planned.isEmpty ? "Add set" : "Add set \(done.count + 1) of \(done.count + planned.count)")
                        .font(.title3.bold())
                }
                .buttonStyle(BentoButtonStyle())

                if let nudge {
                    HStack {
                        Text("Hit \(WorkoutEngine.repRange.upperBound)+ reps. Had more in the tank?")
                            .font(.subheadline)
                        Spacer()
                        Button("Try \(nudge.clean) lb") {
                            weight = nudge
                            reps = WorkoutEngine.repRange.lowerBound
                            self.nudge = nil
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                    }
                    .padding(12)
                    .bentoCard(cornerRadius: 14)
                }

                List {
                    ForEach(Array(done.enumerated()), id: \.element.id) { i, set in
                        HStack {
                            Text("Set \(i + 1)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\((set.weight ?? 0).clean) lb × \(set.reps ?? 0)")
                                .monospacedDigit()
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let set = done[i]
                            entry.sets.removeAll { $0 === set }
                            modelContext.delete(set)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding()
            .background(Color.bentoPaper.ignoresSafeArea())
            .navigationTitle(exercise?.name ?? "Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
        .presentationDetents([.large])
    }

    private func stepper(value: Binding<Double>, step: Double, unit: String, format: @escaping (Double) -> String) -> some View {
        HStack {
            Button {
                value.wrappedValue -= step
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(BentoCircleButtonStyle())

            Spacer()
            VStack(spacing: 0) {
                TextField("0", value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                value.wrappedValue += step
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(BentoCircleButtonStyle())
        }
    }

    /// Next planned target, else repeat the last set, else the suggestion, else last time
    private func prefill() {
        // Flag guessed weights (no history at this gym) whichever way the weight gets filled in
        if lastTime == nil, let exercise {
            let (plan, note) = WorkoutEngine.plan(for: exercise, gym: gym, sessions: sessions.filter { $0 !== entry.session })
            guessNote = plan?.isGuess == true ? note : nil
        }
        if let next = planned.first, next.weight != nil || next.reps != nil {
            weight = next.weight ?? 0
            reps = next.reps ?? 10
        } else if let last = done.last {
            weight = last.weight ?? 0
            reps = last.reps ?? 10
        } else if let exercise {
            let (plan, note) = WorkoutEngine.plan(for: exercise, gym: gym, sessions: sessions.filter { $0 !== entry.session })
            weight = plan?.weight ?? 0
            reps = plan?.targetReps.first ?? 10
            _ = note
        }
    }

    private func addSet() {
        // An easy set at the top of the range: offer the next step (stacks can jump 15 lb)
        if let exercise, weight > 0, reps >= WorkoutEngine.repRange.upperBound {
            let up = WorkoutEngine.nextWeight(after: weight, exercise: exercise, gym: gym, sessions: sessions)
            nudge = up > weight ? up : nil
        } else {
            nudge = nil
        }
        if let next = planned.first {
            next.weight = weight
            next.reps = reps
            next.isPlanned = false
        } else {
            entry.sets.append(WorkoutSet(order: entry.sets.count, weight: weight, reps: reps))
        }
        // Line up the next planned target, if any
        if let following = planned.first, let w = following.weight, let r = following.reps {
            weight = w
            reps = r
        }
    }
}

// MARK: - Exercise Search

struct ExerciseSearchView: View {
    @Environment(ExerciseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""
    @State private var searchText = ""
    let onSelect: (ExerciseDefinition) -> Void

    private static let categoryOrder = ["Push", "Pull", "Legs", "Core", "Back / Lower Back", "Forearms"]

    private var currentGym: Gym? {
        gyms.first { $0.name == currentGymName }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    ForEach(Self.categoryOrder, id: \.self) { category in
                        let items = store.exercises(category: category)
                        if !items.isEmpty {
                            Section(category) {
                                ForEach(items) { row($0) }
                            }
                        }
                    }
                } else {
                    ForEach(store.search(searchText)) { row($0) }
                }
            }
            .bentoScreen()
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises or aliases")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ exercise: ExerciseDefinition) -> some View {
        let allowed = currentGym?.allows(exercise) ?? true
        let q = searchText.lowercased()
        let matchedAlias = q.isEmpty || exercise.name.lowercased().contains(q)
            ? nil : exercise.aliases.first { $0.contains(q) }

        return Button {
            onSelect(exercise)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ExerciseThumbnail(exercise: exercise)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(exercise.name)
                            .font(.body)
                            .foregroundStyle(allowed ? .primary : .secondary)
                        if exercise.isMine {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    HStack(spacing: 8) {
                        if let matchedAlias {
                            Text("aka \(matchedAlias)")
                        } else if let eq = exercise.equipment.first {
                            Text(eq.name)
                        }
                        if !allowed, let gym = currentGym {
                            Text("not at \(gym.name)")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Exercise Thumbnail

struct ExerciseThumbnail: View {
    let exercise: ExerciseDefinition

    var body: some View {
        Group {
            if let url = exercise.imageURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.gray.opacity(0.15)
                }
            } else {
                Image(systemName: "dumbbell.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
