import SwiftUI
import Charts
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
                if let session, !session.entries.isEmpty {
                    Section {
                        let (done, planned) = muscleProgress(session)
                        SessionMuscleFigure(done: done, planned: planned)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
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

    /// Effective sets per muscle so far (targets 1, helpers ½), and muscles still planned
    private func muscleProgress(_ session: WorkoutSession) -> ([Int: Double], Set<Int>) {
        var done: [Int: Double] = [:]
        var planned = Set<Int>()
        for entry in session.entries {
            guard let ex = store.exercise(id: entry.exerciseId) else { continue }
            let n = Double(entry.sets.filter { !$0.isPlanned }.count)
            for m in ex.targetMuscleIds { done[m, default: 0] += n }
            for m in ex.synergistMuscleIds { done[m, default: 0] += n / 2 }
            if entry.sets.contains(where: \.isPlanned) { planned.formUnion(ex.targetMuscleIds) }
        }
        return (done.filter { $0.value > 0 }, planned)
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
        new.plannedCount = reps.count
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
        let ex = store.exercise(id: entry.exerciseId)
        let done = entry.sets.filter { !$0.isPlanned }.count
        let total = max(entry.sets.count, entry.plannedCount)
        let complete = done > 0 && done == total
        HStack(spacing: 12) {
            if let ex {
                ExerciseThumbnail(exercise: ex)
                    .frame(width: 44, height: 44)
                    .opacity(complete ? 0.5 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ex?.name ?? "Exercise")
                    .font(.headline)
                    .strikethrough(complete, color: .secondary)
                    .foregroundStyle(complete ? .secondary : .primary)
                if let ex, !ex.targetMuscles.isEmpty {
                    Text(ex.targetMuscles.prefix(3).map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(progressText(done: done, total: total))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(done > 0 ? Color.bentoActivity : .secondary)
            }
            Spacer()
            Image(systemName: complete ? "checkmark.circle.fill" : done > 0 ? "circle.lefthalf.filled" : "circle")
                .font(.title3)
                .foregroundStyle(done > 0 ? Color.bentoActivity : Color.secondary.opacity(0.4))
        }
        .contentShape(Rectangle())
    }

    /// "2 of 3 done", "3 sets done" (nothing planned), "tap to add sets"
    private func progressText(done: Int, total: Int) -> String {
        let planned = entry.plannedCount > 0
        if total == 0 { return "tap to add sets" }
        if !planned && done == total { return done == 1 ? "1 set done" : "\(done) sets done" }
        return "\(done) of \(total) done"
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
    /// "Guess: …" when there's no history for this exercise here
    @State private var guessNote: String?
    /// Suggested next weight after a set that was easier than expected
    @State private var nudge: WorkoutEngine.Nudge?

    private var exercise: ExerciseDefinition? { store.exercise(id: entry.exerciseId) }
    private var gym: Gym? { gyms.first { $0.name == (entry.session?.gymName ?? currentGymName) } }
    private var done: [WorkoutSet] { entry.sortedSets.filter { !$0.isPlanned } }
    private var planned: [WorkoutSet] { entry.sortedSets.filter(\.isPlanned) }
    private var others: [WorkoutSession] { sessions.filter { $0 !== entry.session } }
    private var bodyweight: Bool { exercise.map(WorkoutEngine.isBodyweight) ?? false }

    private var step: Double {
        guard let exercise else { return 5 }
        return WorkoutEngine.weightStep(for: exercise, gym: gym, sessions: sessions)
    }

    /// "last time 70×12, 85×11" from previous sessions (not this one)
    private var lastTime: String? {
        guard let exercise,
              let last = WorkoutEngine.lastPerformance(of: exercise, gym: gym, sessions: others) else { return nil }
        return "last time " + last.sets.map { WorkoutEngine.label($0, bodyweight: bodyweight) }.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let lastTime {
                        Text(lastTime)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let guessNote {
                        Label(guessNote, systemImage: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 14) {
                        stepper(value: Binding(get: { weight }, set: { weight = max(bodyweight ? 0 : step, $0) }),
                                step: step, unit: bodyweight ? (weight == 0 ? "bodyweight" : "lb added") : "lb",
                                format: { $0.clean })
                        stepper(value: Binding(get: { Double(reps) }, set: { reps = max(1, Int($0)) }),
                                step: 1, unit: "reps", format: { String(Int($0)) })
                    }

                    Button {
                        addSet()
                    } label: {
                        Text(planned.isEmpty ? "Add set \(done.count + 1)" : "Add set \(done.count + 1) of \(done.count + planned.count)")
                            .font(.title3.bold())
                    }
                    .buttonStyle(BentoButtonStyle())

                    if let nudge {
                        HStack {
                            Text(nudge.reason)
                                .font(.subheadline)
                            Spacer()
                            Button("Try \(nudge.weight.clean) lb") {
                                weight = nudge.weight
                                reps = nudge.reps
                                self.nudge = nil
                            }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                        }
                        .padding(12)
                        .bentoCard(cornerRadius: 14)
                    }

                    if !done.isEmpty { setList }

                    if let exercise {
                        ProgressChart(exercise: exercise, gym: gym, history: others, today: done)
                    }
                }
                .padding()
            }
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

    /// Done sets, each with a delete button for typos
    private var setList: some View {
        VStack(spacing: 0) {
            ForEach(Array(done.enumerated()), id: \.element.id) { i, set in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bentoActivity)
                    Text("Set \(i + 1)").foregroundStyle(.secondary)
                    Spacer()
                    Text(WorkoutEngine.label(set, bodyweight: bodyweight, long: true))
                        .monospacedDigit()
                    Button {
                        delete(set)
                    } label: {
                        Image(systemName: "trash").font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .accessibilityLabel("Delete set \(i + 1)")
                }
                .padding(.vertical, 10)
                if i < done.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .bentoCard(cornerRadius: 16)
    }

    /// Removes a logged set; if it filled a planned slot, the slot goes back to planned
    private func delete(_ set: WorkoutSet) {
        if entry.sets.count <= entry.plannedCount {
            set.isPlanned = true
        } else {
            entry.sets.removeAll { $0 === set }
            modelContext.delete(set)
        }
        nudge = nil
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

    /// After a set: what you just did. Before any: the plan, else an estimate (never 0 lb for a weighted lift).
    private func prefill() {
        guard let exercise else { return }
        if let last = done.last {
            weight = last.weight ?? 0
            reps = planned.first?.reps ?? last.reps ?? 10
            return
        }
        let (plan, note) = WorkoutEngine.plan(for: exercise, gym: gym, sessions: others)
        if let next = planned.first, let w = next.weight, w > 0 || bodyweight {
            weight = w
            reps = next.reps ?? 10
        } else if let plan, plan.weight > 0 || bodyweight {
            weight = plan.weight
            reps = plan.targetReps.first ?? 10
        } else if let estimate = WorkoutEngine.startingEstimate(for: exercise, gym: gym, sessions: others, store: store) {
            weight = estimate.weight
            reps = 10
            guessNote = estimate.note
            return
        } else {
            weight = bodyweight ? 0 : step
            reps = 10
            guessNote = bodyweight ? nil : "No history to go on. Start light and adjust."
            return
        }
        guessNote = plan?.isGuess == true ? note : nil
    }

    private func addSet() {
        if let exercise {
            nudge = WorkoutEngine.inSessionNudge(exercise: exercise, gym: gym, sessions: sessions,
                                                 weight: weight, reps: reps, setIndex: done.count,
                                                 previousReps: done.last.flatMap { $0.weight == weight ? $0.reps : nil })
        }
        if let next = planned.first {
            next.weight = weight
            next.reps = reps
            next.isPlanned = false
        } else {
            entry.sets.append(WorkoutSet(order: entry.sets.count, weight: weight, reps: reps))
        }
        // Keep the weight you just used; only the target reps come from the plan
        if let following = planned.first, let r = following.reps { reps = r }
    }
}

/// Top-set weight per session, framed around the data, today's sets in green. Touch a point to see its reps.
struct ProgressChart: View {
    let exercise: ExerciseDefinition
    let gym: Gym?
    let history: [WorkoutSession]
    let today: [WorkoutSet]

    @State private var selected: Date?

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let weight: Double
        let reps: Int
        let isToday: Bool
    }

    var body: some View {
        let gymName = WorkoutEngine.isGymSpecific(exercise) ? gym?.name : nil
        let past = WorkoutEngine.exerciseHistory(exerciseId: exercise.id, sessions: history, gymName: gymName).suffix(12)
        let pastPoints = past.map { Point(date: $0.date, weight: $0.topWeight, reps: $0.topReps, isToday: false) }
        // Today: just the heaviest set (ties: most reps), like the past points
        let todayBest = today.compactMap { s in s.weight.flatMap { w in s.reps.map { (w, $0) } } }
            .max { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { Point(date: .now, weight: $0.0, reps: $0.1, isToday: true) }
        let points = pastPoints + (todayBest.map { [$0] } ?? [])

        if WorkoutEngine.isBodyweight(exercise) || points.count < 2 {
            EmptyView()
        } else {
            // Frame the data: room below the lowest point and above the highest (≥10 lb or 40% of the
            // spread), on round tens, so changes are visible without dead space down to 0
            let lo = points.map(\.weight).min() ?? 0, hi = points.map(\.weight).max() ?? 0
            let pad = max(10, (hi - lo) * 0.4)
            let floor = max(0, ((lo - pad) / 10).rounded(.down) * 10)
            let ceiling = ((hi + pad) / 10).rounded(.up) * 10
            let shown = selected.flatMap { d in points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Top set").font(.headline)
                    Spacer()
                    if let p = shown {
                        Text("\(p.isToday ? "Today" : p.date.formatted(.dateTime.month(.abbreviated).day())) · \(p.weight.clean) lb × \(p.reps)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    } else {
                        Text(gymName.map { "lb · \($0)" } ?? "lb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(pastPoints) { p in
                        LineMark(x: .value("Date", p.date), y: .value("lb", p.weight))
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Date", p.date), y: .value("lb", p.weight))
                            .foregroundStyle(Color.primary)
                            .symbolSize(40)
                    }
                    if let t = todayBest {
                        PointMark(x: .value("Date", t.date), y: .value("lb", t.weight))
                            .foregroundStyle(Color.bentoActivity)
                            .symbolSize(110)
                            .annotation(position: .top, alignment: .trailing, spacing: 4) {
                                Text("today").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                    }
                    if let p = shown {
                        RuleMark(x: .value("Date", p.date))
                            .foregroundStyle(Color.primary.opacity(0.2))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartYScale(domain: floor...max(ceiling, floor + 20))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                // Tap a point to pin its date, weight and reps above the chart; tap again to clear
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geo[frame].origin.x
                                if let d: Date = proxy.value(atX: x) {
                                    let nearest = points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }?.date
                                    selected = (selected == nearest) ? nil : nearest
                                }
                            }
                    }
                }
                .frame(height: 150)
            }
            .padding(14)
            .bentoCard(cornerRadius: 16)
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
