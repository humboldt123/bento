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
        limit: Int = 4,
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

        let carried = CarryOver.pending(sessions: sessions, now: now)
        let allowed: (ExerciseDefinition) -> Bool = { gym?.suggests($0) ?? true }

        // What this split did last time, so the rotating slots pick something different
        let lastSameSplit = sessions
            .filter { $0.isLogged && splitName(of: $0, store: exerciseStore) == split.name }
            .max { $0.date < $1.date }
        let doneLastTime = Set(lastSameSplit?.exerciseIds ?? [])

        /// Best available exercise for a slot: carried over first, then what you've done before here
        func pick(_ ids: [String], avoid: Set<String>) -> ExerciseDefinition? {
            let options = ids.compactMap { exerciseStore.exercise(id: $0) }.filter { allowed($0) && !avoid.contains($0.id) }
            return options.max { a, b in
                func score(_ e: ExerciseDefinition) -> Double {
                    var s = 0.0
                    if carried[e.id] != nil { s += 1000 }
                    if gym?.status(of: e.id) == .confirmed { s += 100 }
                    if let d = lastDone[e.id] { s += 50 + min(30, 30 - now.timeIntervalSince(d) / 86_400 / 7) }
                    if e.isMine { s += 10 }
                    return s
                }
                return score(a) < score(b)
            }
        }

        let slots = Self.slots[split.name] ?? []
        var picked: [ExerciseDefinition] = []
        // Main lifts every time
        for slot in slots.prefix(2) {
            if let e = pick(slot, avoid: Set(picked.map(\.id))) { picked.append(e) }
        }
        // Accessories rotate: the ones skipped last time first, then whatever's carried over
        let accessories = slots.dropFirst(2).sorted { a, b in
            let aCarried = a.contains { carried[$0] != nil }, bCarried = b.contains { carried[$0] != nil }
            if aCarried != bCarried { return aCarried }
            let aDone = a.contains(where: doneLastTime.contains), bDone = b.contains(where: doneLastTime.contains)
            return !aDone && bDone
        }
        for slot in accessories where picked.count < limit - 1 {
            if let e = pick(slot, avoid: Set(picked.map(\.id))) { picked.append(e) }
        }
        // A short core finisher, rotating
        let core = Self.coreSlot.filter { !doneLastTime.contains($0) } + Self.coreSlot
        if let e = pick(Array(core.prefix(4)), avoid: Set(picked.map(\.id))) { picked.append(e) }

        return picked.map { ex in
            let (plan, note) = plan(for: ex, gym: gym, sessions: sessions, now: now)
            if carried[ex.id] != nil {
                return ExerciseSuggestion(exercise: ex, split: split.name, plan: plan,
                                          note: "Skipped last time", kind: .carried)
            }
            return ExerciseSuggestion(exercise: ex, split: split.name, plan: plan, note: note)
        }
    }

    /// Each split as ordered slots: two main lifts, then accessories that rotate. Each slot lists
    /// interchangeable exercises (the gym's confirmed list and your history pick among them).
    static let slots: [String: [[String]]] = [
        "Push": [
            ["my-flat-bench-press", "my-chest-press-machine", "my-dumbbell-bench-press", "my-incline-bench-press"],
            ["my-machine-shoulder-press", "my-dumbbell-shoulder-press", "my-overhead-press-barbell", "my-arnold-press"],
            ["my-pec-deck-machine", "my-cable-fly", "my-dumbbell-fly", "my-incline-dumbbell-fly"],
            ["my-cable-pushdown", "my-triceps-extension-machine", "my-overhead-cable-extension", "my-skull-crusher"],
            ["my-delts-machine", "my-lateral-raise-cable", "my-lateral-raise-dumbbell"],
        ],
        "Pull": [
            ["my-lat-pulldown", "my-reverse-grip-lat-pulldown", "my-pull-up", "my-chin-up"],
            ["my-low-row-machine", "my-cable-row", "my-chest-supported-row", "my-dumbbell-row"],
            ["my-dumbbell-curl", "my-cable-curl", "my-biceps-curl-machine", "my-hammer-curl"],
            ["my-reverse-fly-machine", "my-rear-delt-cable-fly", "my-face-pull"],
            ["my-reverse-curl", "my-hammer-curl"],
        ],
        "Legs": [
            ["my-leg-press", "my-hack-squat", "my-squat", "my-goblet-squat"],
            ["my-leg-curl", "my-seated-leg-curl", "my-romanian-deadlift"],
            ["my-leg-extension", "my-bulgarian-split-squat", "my-walking-lunge"],
            ["my-hip-adductor-machine", "my-hip-abductor-machine", "my-glute-kickback-machine"],
            ["my-calf-extension", "my-standing-calf-raise", "my-seated-calf-raise"],
        ],
    ]

    /// One core exercise at the end of every session, rotating (gym ones first; most work at home too)
    static let coreSlot = ["my-cable-crunch", "my-abdominal-crunch-machine", "my-hanging-leg-raise",
                           "my-decline-sit-up", "my-dead-bug", "my-plank", "my-leg-raise-lying"]

    /// "Push" / "Pull" / "Legs" for a logged session, by its exercises' categories
    static func splitName(of session: WorkoutSession, store: ExerciseStore) -> String? {
        let map = ["Push": "Push", "Pull": "Pull", "Forearms": "Pull", "Legs": "Legs", "Back / Lower Back": "Legs"]
        let names = session.entries.compactMap { store.exercise(id: $0.exerciseId)?.category.flatMap { map[$0] } }
        return Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
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

    /// Double progression: add a rep to each set until every set hits the top of the range, then go up
    /// one weight step. According to the ACSM progression position stand (Ratamess et al., 2009,
    /// Med Sci Sports Exerc 41(3)), load goes up 2–10% once the target is beaten by 1–2 reps on two
    /// consecutive sessions; the NSCA calls this the "2-for-2" rule (Baechle & Earle, 2008).
    /// Strength is compared with the Epley (1985) estimate, $\hat{1RM} = w\,(1 + r/30)$, with $r$ capped at
    /// 15 because rep-based estimates lose accuracy past ~10 reps (LeSuer et al., 1997).
    /// With no history at this gym, guesses from another gym.
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

        // Bodyweight: reps only, no ceiling at 12. Past 20 reps, add load (our threshold, not from a paper)
        if isBodyweight(exercise) {
            let reps = last.sets.compactMap(\.reps)
            if daysOff > comebackDays {
                return (SetPlan(weight: 0, targetReps: reps.map { max(1, $0 - 2) }, lastWeight: 0, lastReps: reps),
                        "Ease back in (\(daysOff / 7) wks off)")
            }
            let added = last.sets.compactMap(\.weight).max() ?? 0
            if (reps.min() ?? 0) >= 20 {
                return (SetPlan(weight: added + 5, targetReps: reps.map { _ in 12 }, lastWeight: added, lastReps: reps),
                        "20+ reps: hold a 5 lb plate")
            }
            return (SetPlan(weight: added, targetReps: reps.map { $0 + 1 }, lastWeight: added, lastReps: reps), "+1 rep")
        }

        // Reference: the better of the last two sessions, so an off day doesn't lower the bar.
        // Epley (1985): $\hat{1RM} = w\,(1 + \min(r, 15)/30)$
        func e1rm(_ x: (top: Double, reps: [Int])) -> Double { x.top * (1 + Double(min(x.reps.max() ?? 0, 15)) / 30) }
        var reference = lastSummary
        var offDay = false
        if recent.count > 1, daysOff <= 14 {
            let prev = summary(recent[1].sets)
            if e1rm(prev) > e1rm(lastSummary) * 1.03 { reference = prev; offDay = true }
        }
        let top = reference.top
        let lastReps = reference.reps
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)
        let topReps = repRange.upperBound

        // Stalled: best-set $\hat{1RM}$ hasn't beaten the session two before it, three times running.
        // The 10% deload is common coaching practice, not a tested rule
        let stalled: Bool = {
            guard recent.count >= 3, daysOff <= 14 else { return false }
            let values = recent.prefix(3).map { e1rm(summary($0.sets)) }   // newest first
            return values[0] <= values[2] * 1.01 && values[1] <= values[2] * 1.01
        }()

        /// Detraining: according to Bosquet et al. (2013, Scand J Med Sci Sports, doi 10.1111/sms.12047),
        /// max strength holds for about 3–4 weeks off and losses speed up after that; reps at a given
        /// load fade sooner. Multipliers on the last top weight, by days off
        let comeback: Double = switch daysOff {
        case ..<15: 1
        case ..<29: 0.95
        case ..<57: 0.90
        case ..<92: 0.82
        default: 0.75
        }

        // Epley (1985) solved for reps at a heavier weight: $r = 30\,(\hat{1RM}/w - 1)$
        func predictedReps(at w: Double) -> Int { Int((30 * (e1rm(reference) / w - 1)).rounded(.down)) }

        var weight: Double
        var reps: [Int]
        var note: String
        let allTop = lastReps.allSatisfy { $0 >= topReps }
        // "2-for-2" (Baechle & Earle, 2008; ACSM, Ratamess et al., 2009): go up after hitting the top
        // two sessions running, or after beating it by 2 reps in one
        let prevAllTop = recent.count > 1 && summary(recent[1].sets).top == top
            && summary(recent[1].sets).reps.allSatisfy { $0 >= topReps }
        let beatBy2 = (lastReps.first ?? 0) >= topReps + 2

        if comeback < 1 {
            weight = max(step, ((top * comeback) / step).rounded(.down) * step)
            reps = Array(repeating: topReps - 2, count: max(lastReps.count, 3))
            note = "Ease back in (\(daysOff / 7) wks off)"
        } else if stalled {
            weight = max(step, ((top * 0.9) / step).rounded(.down) * step)
            reps = Array(repeating: topReps, count: max(lastReps.count, 3))
            note = "Stuck 3 sessions: 10% lighter, build back up"
        } else if allTop && (prevAllTop || beatBy2) {
            let next = top + step
            if step / top > 0.10, predictedReps(at: next) < repRange.lowerBound {
                // ACSM (Ratamess et al., 2009) suggests 2–10% load increases. A stack jump above 10% that
                // Epley predicts would drop you under 8 reps is earned with more reps first
                weight = top
                reps = lastReps.map { min($0 + 1, 16) }
                note = "Next plate is a big jump (+\(step.clean)). Push past \(topReps) reps first"
            } else {
                weight = next
                reps = Array(repeating: repRange.lowerBound, count: lastReps.count)
                note = "+\(step.clean) lb"
            }
        } else if allTop {
            weight = top
            reps = lastReps
            note = "Top of the range again → then go up"
        } else {
            weight = top
            reps = lastReps.map { min(topReps, $0 + 1) }
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
