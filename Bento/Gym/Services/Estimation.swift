import Foundation

// Starting-weight estimates, in-session nudges and set labels. Numbers are tuned from the strength
// literature (see the comments on each constant); everything is rounded down to a real weight.
extension WorkoutEngine {

    // MARK: - Labels

    /// "70×12", or "BW×15" / "BW+10×8" for bodyweight exercises
    static func label(_ set: WorkoutSet, bodyweight: Bool, long: Bool = false) -> String {
        let w = set.weight ?? 0, r = set.reps ?? 0
        if bodyweight {
            return w > 0 ? "BW+\(w.clean)×\(r)" : (long ? "bodyweight × \(r)" : "BW×\(r)")
        }
        return long ? "\(w.clean) lb × \(r)" : "\(w.clean)×\(r)"
    }

    /// Same as label(_:) for a plain weight and rep count
    static func label(weight w: Double, reps r: Int, bodyweight: Bool) -> String {
        bodyweight ? (w > 0 ? "BW+\(w.clean)×\(r)" : "BW×\(r)") : "\(w.clean)×\(r)"
    }

    // MARK: - In-session nudge

    struct Nudge {
        let weight: Double
        let reps: Int
        let reason: String
    }

    /// Too easy = at least the top of the range with no fatigue drop-off. According to Senna et al.
    /// (2009, J Sports Sci Med, PMC3761475), trained men at a 10RM load drop ~1–2 reps on set 2 and
    /// 2–4 on set 3, so holding steady or climbing means reps in reserve. Trained lifters judge reps
    /// in reserve within about 1 rep (Helms et al., 2016, Strength Cond J 38(4); Zourdos et al., 2016),
    /// so set 1 two past the top counts on its own.
    static func inSessionNudge(exercise: ExerciseDefinition, gym: Gym?, sessions: [WorkoutSession],
                               weight: Double, reps: Int, setIndex: Int, previousReps: Int? = nil) -> Nudge? {
        if isBodyweight(exercise) {
            return reps >= 20 ? Nudge(weight: (weight > 0 ? weight : 0) + 5, reps: 12,
                                      reason: "\(reps) reps. Hold a 5 lb plate?") : nil
        }
        guard weight > 0 else { return nil }
        let top = repRange.upperBound
        let noDropoff = previousReps.map { reps >= $0 } ?? false
        guard reps >= top + 2 || (reps >= top && noDropoff) || (setIndex == 0 && reps >= top + 1) else { return nil }
        let next = nextWeight(after: weight, exercise: exercise, gym: gym, sessions: sessions)
        guard next > weight else { return nil }
        // Epley (1985): $\hat{1RM} = w\,(1 + r/30)$, so reps at the next weight $w'$ are
        // $r' = 30\,(\hat{1RM}/w' - 1)$
        let e1rm = weight * (1 + Double(min(reps, 15)) / 30)
        let predicted = Int((30 * (e1rm / next - 1)).rounded(.down))
        guard predicted >= repRange.lowerBound - 1 else { return nil }
        let reason = noDropoff
            ? "\(reps) reps and no drop-off. Next weight?"
            : "\(reps) reps on set \(setIndex + 1). Go up?"
        return Nudge(weight: next, reps: max(repRange.lowerBound, min(predicted, top)), reason: reason)
    }

    // MARK: - Starting estimate

    /// How heavy one lift is relative to another for the same muscles, as a multiplier on e1RM.
    /// Keys are equipment classes; values are (ratio, source).
    enum Kind: String { case barbell, dumbbell, machine, cable, smith, bodyweight, other }

    static func kind(_ exercise: ExerciseDefinition) -> Kind {
        let eq = Set(exercise.equipmentIds)
        if eq.contains(1) || eq.contains(5) || eq.contains(26) { return .barbell }
        if eq.contains(4) { return .dumbbell }
        if eq.contains(8) { return .smith }
        if eq.contains(6) || eq.contains(7) { return .machine }
        if eq.contains(3) { return .cable }
        if eq.isSubset(of: [2]) && !eq.isEmpty { return .bodyweight }
        return .other
    }

    /// Multiplier from a known lift's e1RM (by kind) to an unknown one. Dumbbell numbers are per hand.
    /// Barbell→dumbbell press ≈ 0.4 per hand (a dumbbell pair lifts ~80% of the barbell). These are
    /// practitioner norms, not trial data; machines vary a lot by leverage.
    static func ratio(from: Kind, to: Kind) -> Double {
        if from == to { return 1 }
        switch (from, to) {
        case (.barbell, .dumbbell): return 0.40
        case (.dumbbell, .barbell): return 2.3
        case (.barbell, .machine), (.barbell, .smith): return 1.0
        case (.machine, .barbell), (.smith, .barbell): return 0.9
        case (.dumbbell, .machine): return 2.0
        case (.machine, .dumbbell): return 0.4
        case (.cable, .machine), (.machine, .cable): return 0.8
        case (.barbell, .cable): return 0.6
        case (.cable, .barbell): return 1.4
        case (.dumbbell, .cable): return 1.4
        case (.cable, .dumbbell): return 0.6
        default: return 0.8
        }
    }

    /// Unknown machines are the riskiest, so start well under the estimate (70–80%). Our own margin:
    /// rep-based 1RM estimates are typically off by 5–10% (LeSuer et al., 1997)
    static let safetyFactor = 0.75

    /// Movement patterns with known strength ratios (per hand for dumbbells)
    enum Pattern: String { case flatPress, inclinePress, overheadPress, chestPress, pulldown, row, legPress, legExtension, legCurl, curl }

    static func pattern(_ e: ExerciseDefinition) -> Pattern? {
        let n = e.name.lowercased()
        if n.contains("incline") && n.contains("press") { return .inclinePress }
        if n.contains("shoulder press") || n.contains("overhead press") || n.contains("arnold") { return .overheadPress }
        if n.contains("chest press") { return .chestPress }
        if n.contains("bench press") { return .flatPress }
        if n.contains("pulldown") || n.contains("pull-up") || n.contains("chin-up") { return .pulldown }
        if n.contains("row") && !n.contains("upright") { return .row }
        if n.contains("leg press") || n.contains("hack squat") { return .legPress }
        if n.contains("leg extension") { return .legExtension }
        if n.contains("leg curl") { return .legCurl }
        if n.contains("curl") && !n.contains("wrist") && !n.contains("leg") { return .curl }
        return nil
    }

    /// e1RM multiplier from one pattern to another. Mostly practitioner norms (machines vary ±30%),
    /// so the conservative end of each range: incline 0.8–0.9 of flat, shoulder press 0.6–0.7, machine
    /// chest press 0.8–1.3, row ≈ pulldown, leg extension 0.25–0.4 and leg curl 0.2–0.3 of leg press.
    static func patternRatio(from: Pattern, to: Pattern) -> Double? {
        let level: [Pattern: Double] = [
            .flatPress: 1, .inclinePress: 0.85, .overheadPress: 0.62, .chestPress: 0.85,
        ]
        let pull: [Pattern: Double] = [.pulldown: 1, .row: 0.95]
        let legs: [Pattern: Double] = [.legPress: 1, .legExtension: 0.3, .legCurl: 0.22]
        for table in [level, pull, legs] {
            if let a = table[from], let b = table[to] { return b / a }
        }
        return from == to ? 1 : nil
    }

    /// For an exercise with no history anywhere: borrow from the most similar exercise you've done
    /// (same primary muscles, same movement where possible), convert by equipment, apply a safety
    /// factor, and turn the e1RM into a 10-rep working weight.
    static func startingEstimate(for exercise: ExerciseDefinition, gym: Gym?, sessions: [WorkoutSession],
                                 store: ExerciseStore) -> (weight: Double, note: String)? {
        guard !isBodyweight(exercise) else { return nil }
        let targets = Set(exercise.targetMuscleIds)
        guard !targets.isEmpty else { return nil }

        // Best recent e1RM for every other exercise, scored by muscle overlap (same pattern wins)
        var best: (ex: ExerciseDefinition, e1rm: Double, score: Double)?
        let ids = Set(sessions.flatMap(\.exerciseIds)).subtracting([exercise.id])
        for id in ids {
            guard let other = store.exercise(id: id), !isBodyweight(other) else { continue }
            let overlap = Double(targets.intersection(other.targetMuscleIds).count) / Double(targets.count)
            guard overlap >= 0.5 || (pattern(other).flatMap { a in pattern(exercise).flatMap { patternRatio(from: a, to: $0) } } != nil) else { continue }
            let history = exerciseHistory(exerciseId: id, sessions: sessions).suffix(3)
            guard let e1rm = history.map(\.estimated1RM).max(), e1rm > 0 else { continue }
            let sameCategory = other.category == exercise.category ? 0.2 : 0
            let samePattern = pattern(other).flatMap { a in pattern(exercise).flatMap { patternRatio(from: a, to: $0) } } != nil ? 1.0 : 0
            let score = overlap + sameCategory + samePattern
            if best == nil || score > best!.score { best = (other, e1rm, score) }
        }
        guard let best else { return nil }

        // Same movement family: use the pattern ratio, then adjust for dumbbells (per hand ≈ 0.4)
        var factor = ratio(from: kind(best.ex), to: kind(exercise))
        if let a = pattern(best.ex), let b = pattern(exercise), let r = patternRatio(from: a, to: b) {
            factor = r
            if kind(exercise) == .dumbbell && kind(best.ex) != .dumbbell { factor *= 0.4 }
            if kind(best.ex) == .dumbbell && kind(exercise) != .dumbbell { factor /= 0.4 }
        }
        let e1rm = best.e1rm * factor * safetyFactor
        // Aim for ~12 easy reps. Epley (1985) solved for weight: $w = \hat{1RM} / (1 + 12/30) = \hat{1RM}/1.4$.
        // Then calibrate from set 1
        var weight = e1rm / (1 + 12.0 / 30)
        let step = weightStep(for: exercise, gym: gym, sessions: sessions)
        weight = max(step, (weight / step).rounded(.down) * step)
        if exercise.equipmentIds.contains(4), let gym { weight = gym.snapDumbbell(weight) }
        return (weight, "Guess from your \(best.ex.name), on the light side. Adjust after set 1.")
    }
}
