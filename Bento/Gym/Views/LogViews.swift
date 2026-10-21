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

/// One value per session (best weight, est. 1RM, most reps or volume) as a filled line. Sessions sit
/// one step apart and a break widens the step logarithmically, so a 3-month gap shows without
/// eating the width. Tap a point for that day.
struct ProgressChart: View {
    let exercise: ExerciseDefinition
    let gym: Gym?
    let history: [WorkoutSession]
    let today: [WorkoutSet]

    enum Metric: String, CaseIterable {
        case weight = "Weight", oneRM = "1RM", reps = "Reps", volume = "Volume"
    }

    @AppStorage("progressMetric") private var metric: Metric = .weight
    @State private var selected: Int?

    private struct Day: Identifiable {
        var id: Int { index }
        let index: Int
        let x: Double
        let date: Date
        let sets: [(weight: Double, reps: Int)]

        func value(_ m: Metric) -> Double {
            switch m {
            case .weight: sets.map(\.weight).max() ?? 0
            case .oneRM: sets.map { $0.weight * (1 + Double(min($0.reps, 15)) / 30) }.max() ?? 0
            case .reps: Double(sets.map(\.reps).max() ?? 0)
            case .volume: sets.reduce(0) { $0 + $1.weight * Double($1.reps) }
            }
        }
    }

    private var bodyweight: Bool { WorkoutEngine.isBodyweight(exercise) }
    private var metrics: [Metric] { bodyweight ? [.reps] : Metric.allCases }
    private var shownMetric: Metric { metrics.contains(metric) ? metric : metrics[0] }

    private static func working(_ sets: [WorkoutSet]) -> [(weight: Double, reps: Int)] {
        sets.filter { !$0.isPlanned }.compactMap { s in
            guard let r = s.reps, r > 0 else { return nil }
            return (s.weight ?? 0, r)
        }
    }

    /// Last 20 sessions (this gym for machines), plus today's sets if they aren't saved yet
    private func makeDays() -> [Day] {
        let gymName = WorkoutEngine.isGymSpecific(exercise) ? gym?.name : nil
        var raw: [(Date, [(weight: Double, reps: Int)])] = history
            .filter { gymName == nil || $0.gymName == gymName }
            .sorted { $0.date < $1.date }
            .compactMap { session in
                guard let entry = session.entries.first(where: { $0.exerciseId == exercise.id }) else { return nil }
                let sets = Self.working(entry.sets)
                return sets.isEmpty ? nil : (session.date, sets)
            }
            .suffix(20)
        let todays = Self.working(today)
        if !todays.isEmpty, !raw.contains(where: { Calendar.current.isDateInToday($0.0) }) {
            raw.append((.now, todays))
        }
        var days: [Day] = []
        var x = 0.0
        for (i, r) in raw.enumerated() {
            if let prev = days.last {
                // A week or less is one step; longer breaks add log2(weeks) × 0.4 (3 months ≈ +1.5)
                let weeks = max(1, r.0.timeIntervalSince(prev.date) / 604_800)
                x += 1 + 0.4 * log2(weeks)
            }
            days.append(Day(index: i, x: x, date: r.0, sets: r.1))
        }
        return days
    }

    private func format(_ v: Double) -> String {
        switch shownMetric {
        case .reps: "\(Int(v))"
        case .volume: v >= 10_000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))"
        default: ((v * 10).rounded() / 10).clean
        }
    }

    private var unit: String { shownMetric == .reps ? "reps" : "lb" }

    var body: some View {
        let days = makeDays()

        if days.count < 2 {
            EmptyView()
        } else {
            let m = shownMetric
            let values = days.map { $0.value(m) }
            let lo = values.min()!, hi = values.max()!
            let pad = max(m == .reps ? 1 : 5, (hi - lo) * 0.15)
            let yMin = max(0, lo - pad)
            let yMax = hi + pad
            let xMax = days.last!.x
            let shown = selected.flatMap { i in days.first { $0.index == i } } ?? days.last!
            let delta = shown.value(m) - values[0]

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected == nil ? "Progress" : shown.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.headline)
                        if selected != nil {
                            Text(shown.sets.map { WorkoutEngine.label(weight: $0.weight, reps: $0.reps, bodyweight: bodyweight) }
                                    .joined(separator: ", "))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    Spacer()
                    Text(format(shown.value(m)))
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                    Text(unit).font(.subheadline).foregroundStyle(.secondary)
                    if delta != 0 {
                        Text("\(delta > 0 ? "+" : "−")\(format(abs(delta)))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(delta > 0 ? Color.bentoActivity : .red)
                    }
                }

                Chart {
                    ForEach(days) { d in
                        AreaMark(x: .value("Session", d.x), yStart: .value("min", yMin), yEnd: .value(unit, d.value(m)))
                            .foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Session", d.x), y: .value(unit, d.value(m)))
                            .foregroundStyle(Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("Session", d.x), y: .value(unit, d.value(m)))
                            .foregroundStyle(Color.primary)
                            .symbolSize(d.index == selected ? 110 : 30)
                    }
                }
                .chartXScale(domain: -0.3...(xMax + 0.3))
                .chartYScale(domain: yMin...yMax)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let frame = proxy.plotFrame,
                                      let x: Double = proxy.value(atX: location.x - geo[frame].origin.x),
                                      let near = days.min(by: { abs($0.x - x) < abs($1.x - x) }) else { return }
                                selected = selected == near.index ? nil : near.index
                            }
                    }
                }
                .frame(height: 190)

                if metrics.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(metrics, id: \.self) { option in
                            Button(option.rawValue) { metric = option }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(option == m ? Color.primary : Color.primary.opacity(0.07)))
                                .foregroundStyle(option == m ? Color.bentoPaper : .primary)
                                .buttonStyle(.plain)
                        }
                    }
                }
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
