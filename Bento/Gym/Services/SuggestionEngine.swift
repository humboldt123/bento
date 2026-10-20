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
            .filter { gym?.allows($0) ?? true }

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
            .filter { gym?.allows($0) ?? true }
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

    /// Working sets from the most recent time you did this (at this gym, for machines)
    static func lastPerformance(
        of exercise: ExerciseDefinition,
        gym: Gym?,
        sessions: [WorkoutSession]
    ) -> (date: Date, sets: [WorkoutSet])? {
        let gymSpecific = isGymSpecific(exercise) && gym != nil
        for session in sessions.sorted(by: { $0.date > $1.date }) {
            if gymSpecific, session.gymName != gym?.name { continue }
            guard let entry = session.entries.first(where: { $0.exerciseId == exercise.id }) else { continue }
            let working = entry.sortedSets.filter {
                $0.weight != nil && $0.reps != nil && !$0.tags.contains(SetTag.warmup.rawValue)
            }
            if !working.isEmpty { return (session.date, working) }
        }
        return nil
    }

    /// Reps first: add a rep to each set until every set hits the top of the range, then
    /// go up one weight step. After a long break, start lighter.
    static func plan(
        for exercise: ExerciseDefinition,
        gym: Gym?,
        sessions: [WorkoutSession],
        now: Date = .now
    ) -> (SetPlan?, String?) {
        guard let last = lastPerformance(of: exercise, gym: gym, sessions: sessions) else {
            if let gym, isGymSpecific(exercise) {
                return (nil, "First time at \(gym.name)")
            }
            return (nil, nil)
        }

        let top = last.sets.compactMap(\.weight).max() ?? 0
        let lastReps = last.sets.filter { $0.weight == top }.compactMap(\.reps)
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)
        let daysOff = Calendar.current.dateComponents([.day], from: last.date, to: now).day ?? 0

        var weight: Double
        var reps: [Int]
        var note: String

        if daysOff > comebackDays {
            weight = max(step, ((top * 0.85) / step).rounded(.down) * step)
            reps = Array(repeating: repRange.upperBound - 2, count: max(lastReps.count, 3))
            note = "Ease back in (\(daysOff / 7) wks off)"
        } else if lastReps.allSatisfy({ $0 >= repRange.upperBound }) {
            weight = top + step
            reps = Array(repeating: repRange.lowerBound, count: lastReps.count)
            note = "+\(step.clean) lb"
        } else {
            weight = top
            reps = lastReps.map { min(repRange.upperBound, $0 + 1) }
            note = "+1 rep"
        }

        if let cap = gym?.dumbbellMax, exercise.equipmentIds.contains(4), weight > cap {
            weight = cap
            reps = Array(repeating: repRange.upperBound, count: reps.count)
            note = "Max dumbbell, go for reps"
        }

        return (SetPlan(weight: weight, targetReps: reps, lastWeight: top, lastReps: lastReps), note)
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
