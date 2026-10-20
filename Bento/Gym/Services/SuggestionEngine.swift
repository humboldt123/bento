import Foundation

/// Exercises skipped in a session, carried to the top of the next session for that split.
/// Stored as exercise id -> day it was skipped.
@MainActor
enum CarryOver {
    private static let key = "carryOver"

    static var all: [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func add(_ exerciseIds: [String], on date: Date = .now) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        for id in exerciseIds { raw[id] = date.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func remove(_ exerciseId: String) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        raw[exerciseId] = nil
        UserDefaults.standard.set(raw, forKey: key)
    }

    /// Carried exercises not yet logged on a later day, skipped before today
    static func pending(sessions: [WorkoutSession], now: Date = .now) -> [String: Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return all.filter { id, skippedOn in
            let skippedDay = calendar.startOfDay(for: skippedOn)
            guard skippedDay < today else { return false }
            let loggedSince = sessions.contains { session in
                calendar.startOfDay(for: session.date) > skippedDay && session.exerciseIds.contains(id)
            }
            return !loggedSince
        }
    }
}

extension WorkoutEngine {

    // MARK: - Types

    struct SetPlan {
        let weight: Double
        let targetReps: [Int]
        let lastWeight: Double
        let lastReps: [Int]
        /// No history here: weight estimated from another gym, worth double-checking
        var isGuess = false
    }

    struct ExerciseSuggestion: Identifiable {
        enum Kind { case normal, carried, substitute, later }

        var id: String { exercise.id }
        let exercise: ExerciseDefinition
        let split: String
        let plan: SetPlan?
        let note: String?
        var kind: Kind = .normal
    }

    static let repRange = 8...12
    private static let comebackDays = 21

    // MARK: - Suggestions

    /// Today's suggested session at `gym`: the split trained longest ago, with skipped
    /// exercises from last time first, then what you've done before.
    static func suggestions(
        sessions: [WorkoutSession],
        exerciseStore: ExerciseStore,
        gym: Gym?,
        limit: Int = 6,
        /// "Push" / "Pull" / "Legs" to override the automatic pick
        split forced: String? = nil,
        now: Date = .now
    ) -> [ExerciseSuggestion] {
        // When each muscle was last trained (any gym)
        var muscleLastWorked: [Int: Date] = [:]
        var lastDone: [String: Date] = [:]
        for session in sessions {
            for entry in session.entries {
                if lastDone[entry.exerciseId].map({ session.date > $0 }) ?? true {
                    lastDone[entry.exerciseId] = session.date
                }
                guard let ex = exerciseStore.exercise(id: entry.exerciseId) else { continue }
                for m in ex.targetMuscleIds where muscleLastWorked[m].map({ session.date > $0 }) ?? true {
                    muscleLastWorked[m] = session.date
                }
            }
        }

        // The split trained longest ago (by its most recently worked muscle). This also gives
        // anything trained in the last 48h the lowest priority.
        func timeSinceTrained(_ muscles: Set<Int>) -> Double {
            guard let last = muscles.compactMap({ muscleLastWorked[$0] }).max() else { return .infinity }
            return now.timeIntervalSince(last)
        }
        let splits: [(name: String, muscles: Set<Int>, categories: [String])] = [
            ("Push", [25, 24, 8, 9, 44], ["Push"]),
            ("Pull", [20, 4, 5, 6, 10, 42, 43], ["Pull", "Forearms"]),
            ("Legs", [27, 17, 13, 14, 12, 32], ["Legs", "Back / Lower Back"]),
        ]
        let split = forced.flatMap { name in splits.first { $0.name == name } }
            ?? splits.max { timeSinceTrained($0.muscles) < timeSinceTrained($1.muscles) }!

        let pool = split.categories
            .flatMap { exerciseStore.exercises(category: $0) }
            .filter { gym?.suggests($0) ?? true }

        let carried = CarryOver.pending(sessions: sessions, now: now)

        func rank(_ ex: ExerciseDefinition) -> Int {
            var score = 0
            if carried[ex.id] != nil { score += 1000 }
            if gym?.status(of: ex.id) == .confirmed { score += 100 }
            if lastDone[ex.id] != nil { score += 50 }
            if ex.isMine { score += 10 }
            return score
        }
        let ordered = pool.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra > rb }
            let la = lastDone[a.id] ?? .distantPast, lb = lastDone[b.id] ?? .distantPast
            if la != lb { return la > lb }
            return a.name < b.name
        }

        // At most two exercises with the exact same primary muscles
        var picked: [ExerciseDefinition] = []
        var usedTargets: [Set<Int>] = []
        for ex in ordered where picked.count < limit {
            let targets = Set(ex.targetMuscleIds)
            if usedTargets.filter({ $0 == targets }).count >= 2 { continue }
            picked.append(ex)
            usedTargets.append(targets)
        }

        return picked.map { ex in
            let (plan, note) = plan(for: ex, gym: gym, sessions: sessions, now: now)
            if carried[ex.id] != nil {
                return ExerciseSuggestion(exercise: ex, split: split.name, plan: plan,
                                          note: "Skipped last time", kind: .carried)
            }
            return ExerciseSuggestion(exercise: ex, split: split.name, plan: plan, note: note)
        }
    }

    /// Swaps each taken machine for a substitute hitting the same muscles, and moves the
    /// original to the end so you can try it again later in the session.
    static func applyingTaken(
        _ suggestions: [ExerciseSuggestion],
        taken: Set<String>,
        exerciseStore: ExerciseStore,
        gym: Gym?,
        sessions: [WorkoutSession],
        now: Date = .now
    ) -> [ExerciseSuggestion] {
        guard !taken.isEmpty else { return suggestions }
        var result: [ExerciseSuggestion] = []
        var later: [ExerciseSuggestion] = []
        var used = Set(suggestions.map(\.exercise.id))

        for s in suggestions {
            guard taken.contains(s.exercise.id) else { result.append(s); continue }
            if let sub = substitute(for: s.exercise, excluding: used.union(taken), exerciseStore: exerciseStore, gym: gym, sessions: sessions) {
                used.insert(sub.id)
                let (plan, _) = plan(for: sub, gym: gym, sessions: sessions, now: now)
                result.append(ExerciseSuggestion(exercise: sub, split: s.split, plan: plan,
                                                 note: "Instead of \(s.exercise.name)", kind: .substitute))
            }
            later.append(ExerciseSuggestion(exercise: s.exercise, split: s.split, plan: s.plan,
                                            note: "Taken — try later", kind: .later))
        }
        return result + later
    }

    /// Best stand-in for `exercise`: same target muscles, available here, ideally a different
    /// kind of equipment (machine taken → cable or dumbbells).
    static func substitute(
        for exercise: ExerciseDefinition,
        excluding: Set<String>,
        exerciseStore: ExerciseStore,
        gym: Gym?,
        sessions: [WorkoutSession]
    ) -> ExerciseDefinition? {
        let targets = Set(exercise.targetMuscleIds)
        let done = Set(sessions.flatMap(\.exerciseIds))
        return exerciseStore.exercises
            .filter { $0.id != exercise.id && !excluding.contains($0.id) }
            .filter { gym?.suggests($0) ?? true }
            .compactMap { ex -> (ExerciseDefinition, Int)? in
                let overlap = targets.intersection(ex.targetMuscleIds).count
                guard overlap > 0 else { return nil }
                var score = overlap * 10
                if gym?.status(of: ex.id) == .confirmed { score += 5 }
                if Set(ex.equipmentIds) != Set(exercise.equipmentIds) { score += 3 }
                if done.contains(ex.id) { score += 2 }
                return (ex, score)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: - Progression

    /// Machines and cables differ between gyms, so their history only counts at the same gym.
    /// Free weights carry over everywhere.
    static func isGymSpecific(_ exercise: ExerciseDefinition) -> Bool {
        !Set(exercise.equipmentIds).isDisjoint(with: [3, 6, 7, 8]) // cable, leverage, sled, smith
    }

    /// No weight on the exercise itself (push-ups, pull-ups…): progressed by reps
    static func isBodyweight(_ exercise: ExerciseDefinition) -> Bool {
        let eq = Set(exercise.equipmentIds)
        return !eq.isEmpty && eq.isSubset(of: [2])
    }

    /// Working sets from recent sessions, newest first (at this gym, for machines)
    static func recentPerformances(
        of exercise: ExerciseDefinition,
        gym: Gym?,
        sessions: [WorkoutSession],
        limit: Int = 4
    ) -> [(date: Date, sets: [WorkoutSet])] {
        let gymSpecific = isGymSpecific(exercise) && gym != nil
        let bodyweight = isBodyweight(exercise)
        var out: [(Date, [WorkoutSet])] = []
        for session in sessions.sorted(by: { $0.date > $1.date }) where out.count < limit {
            if gymSpecific, session.gymName != gym?.name { continue }
            guard let entry = session.entries.first(where: { $0.exerciseId == exercise.id }) else { continue }
            let working = entry.sortedSets.filter {
                !$0.isPlanned && $0.reps != nil && ($0.weight != nil || bodyweight)
                    && !$0.tags.contains(SetTag.warmup.rawValue)
            }
            if !working.isEmpty { out.append((session.date, working)) }
        }
        return out.map { (date: $0.0, sets: $0.1) }
    }

    /// Working sets from the most recent time you did this (at this gym, for machines)
    static func lastPerformance(
        of exercise: ExerciseDefinition,
        gym: Gym?,
        sessions: [WorkoutSession]
    ) -> (date: Date, sets: [WorkoutSet])? {
        recentPerformances(of: exercise, gym: gym, sessions: sessions, limit: 1).first
    }

    /// Top weight and the reps done at it
    private static func summary(_ sets: [WorkoutSet]) -> (top: Double, reps: [Int]) {
        let top = sets.compactMap(\.weight).max() ?? 0
        return (top, sets.filter { ($0.weight ?? 0) == top }.compactMap(\.reps))
    }

    /// Reps first: add a rep to each set until every set hits the top of the range, then go up one
    /// weight step. Looks at the last few sessions, so one off day doesn't drop the target, and a
    /// stall (no progress three times) resets lighter. After a long break, start lighter. With no
    /// history at this gym, guesses from another gym.
    static func plan(
        for exercise: ExerciseDefinition,
        gym: Gym?,
        sessions: [WorkoutSession],
        now: Date = .now
    ) -> (SetPlan?, String?) {
        let recent = recentPerformances(of: exercise, gym: gym, sessions: sessions)
        guard let last = recent.first else { return guess(for: exercise, gym: gym, sessions: sessions) }

        let isDumbbell = exercise.equipmentIds.contains(4)
        func snap(_ w: Double) -> Double { isDumbbell ? (gym?.snapDumbbell(w) ?? w) : w }

        let lastSummary = summary(last.sets)
        let daysOff = Calendar.current.dateComponents([.day], from: last.date, to: now).day ?? 0

        // Bodyweight: reps only, no ceiling at 12
        if isBodyweight(exercise) {
            let reps = last.sets.compactMap(\.reps)
            if daysOff > comebackDays {
                return (SetPlan(weight: 0, targetReps: reps.map { max(1, $0 - 2) }, lastWeight: 0, lastReps: reps),
                        "Ease back in (\(daysOff / 7) wks off)")
            }
            return (SetPlan(weight: 0, targetReps: reps.map { $0 + 1 }, lastWeight: 0, lastReps: reps), "+1 rep")
        }

        // Reference: the better of the last two sessions, so an off day doesn't lower the bar
        var reference = lastSummary
        var offDay = false
        if recent.count > 1 {
            let prev = summary(recent[1].sets)
            let lastScore = lastSummary.top * 100 + Double(lastSummary.reps.reduce(0, +))
            let prevScore = prev.top * 100 + Double(prev.reps.reduce(0, +))
            if prevScore > lastScore, daysOff <= comebackDays {
                reference = prev
                offDay = true
            }
        }
        let top = reference.top
        let lastReps = reference.reps
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)

        // Stalled: three sessions at the same top weight without more total reps
        let stalled: Bool = {
            guard recent.count >= 3 else { return false }
            let three = recent.prefix(3).map { summary($0.sets) }
            guard three.allSatisfy({ $0.top == three[0].top }) else { return false }
            let totals = three.map { $0.reps.reduce(0, +) }   // newest first
            return totals[0] <= totals[2]
        }()

        var weight: Double
        var reps: [Int]
        var note: String

        if daysOff > comebackDays {
            weight = max(step, ((top * 0.85) / step).rounded(.down) * step)
            reps = Array(repeating: repRange.upperBound - 2, count: max(lastReps.count, 3))
            note = "Ease back in (\(daysOff / 7) wks off)"
        } else if stalled {
            weight = max(step, ((top * 0.9) / step).rounded(.down) * step)
            reps = Array(repeating: repRange.upperBound, count: max(lastReps.count, 3))
            note = "Stuck 3 sessions: reset lighter, build back up"
        } else if lastReps.allSatisfy({ $0 >= repRange.upperBound }) {
            weight = top + step
            reps = Array(repeating: repRange.lowerBound, count: lastReps.count)
            note = "+\(step.clean) lb"
        } else {
            weight = top
            reps = lastReps.map { min(repRange.upperBound, $0 + 1) }
            note = offDay ? "Off day last time, aiming from the one before" : "+1 rep"
        }

        weight = snap(weight)
        if let cap = gym?.dumbbellMax, isDumbbell, weight >= cap, top >= cap {
            weight = cap
            reps = Array(repeating: repRange.upperBound, count: reps.count)
            note = "Max dumbbell, go for reps"
        }

        return (SetPlan(weight: weight, targetReps: reps, lastWeight: lastSummary.top, lastReps: lastSummary.reps), note)
    }

    /// No history at this gym: take the same exercise elsewhere, a bit lighter (machines differ),
    /// and say it's a guess
    private static func guess(for exercise: ExerciseDefinition, gym: Gym?, sessions: [WorkoutSession]) -> (SetPlan?, String?) {
        guard let gym, isGymSpecific(exercise) else { return (nil, nil) }
        guard let other = recentPerformances(of: exercise, gym: nil, sessions: sessions, limit: 1).first,
              let otherGym = sessions.first(where: { $0.date == other.date })?.gymName else {
            return (nil, "First time at \(gym.name)")
        }
        let s = summary(other.sets)
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)
        var weight = max(step, ((s.top * 0.8) / step).rounded(.down) * step)
        if exercise.equipmentIds.contains(4) { weight = gym.snapDumbbell(weight) }
        let plan = SetPlan(weight: weight, targetReps: [10, 10, 10], lastWeight: s.top, lastReps: s.reps, isGuess: true)
        return (plan, "Guess: ~80% of \(otherGym) (\(s.top.clean) lb)")
    }

    /// Next weight up from `weight` for this exercise (snapped for dumbbells)
    static func nextWeight(after weight: Double, exercise: ExerciseDefinition, gym: Gym?, sessions: [WorkoutSession]) -> Double {
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)
        let next = weight + step
        return exercise.equipmentIds.contains(4) ? (gym?.snapDumbbell(next) ?? next) : next
    }

    /// Smallest jump between weights you've used on this machine, else a sensible default.
    /// Matrix stacks go up 15 lb on some stations, so learning it beats guessing.
    static func weightStep(for exercise: ExerciseDefinition, gym: Gym?, sessions: [WorkoutSession]) -> Double {
        let isDumbbell = exercise.equipmentIds.contains(4)
        if isDumbbell, let step = gym?.dumbbellStep { return step }

        let gymSpecific = isGymSpecific(exercise) && gym != nil
        let weights = Set(sessions
            .filter { !gymSpecific || $0.gymName == gym?.name }
            .flatMap(\.entries)
            .filter { $0.exerciseId == exercise.id }
            .flatMap(\.sets)
            .compactMap(\.weight))
            .sorted()
        let diffs = zip(weights.dropFirst(), weights).map { $0 - $1 }.filter { $0 >= 2.5 }
        if let smallest = diffs.min() { return smallest }

        if exercise.equipmentIds.contains(6) || exercise.equipmentIds.contains(7) { return 10 }
        return 5
    }
}
