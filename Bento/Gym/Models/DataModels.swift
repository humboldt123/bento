import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id = UUID()
    var date = Date.now
    var gymName: String?
    var notes: String?
    @Relationship(deleteRule: .cascade) var entries = [WorkoutEntry]()

    init(date: Date = .now, gymName: String? = nil) {
        self.date = date
        self.gymName = gymName
    }

    var sortedEntries: [WorkoutEntry] {
        entries.sorted { $0.order < $1.order }
    }

    var totalSets: Int {
        entries.reduce(0) { $0 + $1.sets.filter { !$0.isPlanned }.count }
    }

    /// Has at least one set actually done (not just planned from a suggestion)
    var isLogged: Bool { totalSets > 0 }

    var totalVolume: Double {
        entries.reduce(0) { total, entry in
            total + entry.sets.reduce(0) { setTotal, s in
                setTotal + (s.weight ?? 0) * Double(s.reps ?? 0)
            }
        }
    }

    var exerciseIds: [String] {
        sortedEntries.map(\.exerciseId)
    }
}

@Model
final class WorkoutEntry {
    var id = UUID()
    var exerciseId = ""
    var order = 0
    var note: String?
    /// How many sets the suggestion planned (stays after they're done, for "2 of 3 done")
    var plannedCount = 0
    var session: WorkoutSession?
    @Relationship(deleteRule: .cascade) var sets = [WorkoutSet]()

    init(exerciseId: String, order: Int) {
        self.exerciseId = exerciseId
        self.order = order
    }

    var sortedSets: [WorkoutSet] {
        sets.sorted { $0.order < $1.order }
    }

    var bestEstimated1RM: Double? {
        sets.compactMap(\.estimated1RM).max()
    }

    var topWeight: Double? {
        sets.compactMap(\.weight).max()
    }
}

@Model
final class WorkoutSet {
    var id = UUID()
    var order = 0
    var weight: Double?
    var reps: Int?
    var tags = [String]()
    var note: String?
    /// Prefilled from a suggestion (target weight/reps) and not done yet; dropped on finish
    var isPlanned = false
    var entry: WorkoutEntry?

    init(order: Int, weight: Double? = nil, reps: Int? = nil) {
        self.order = order
        self.weight = weight
        self.reps = reps
    }

    /// Planned (not yet done) sets never count toward history, PRs or charts
    var estimated1RM: Double? {
        guard !isPlanned, let w = weight, w > 0, let r = reps, r > 0 else { return nil }
        if r == 1 { return w }
        return w * (1.0 + Double(r) / 30.0)
    }

    var volume: Double {
        isPlanned ? 0 : (weight ?? 0) * Double(reps ?? 0)
    }

    var displayText: String {
        let w = weight.map { "\($0.clean) lb" } ?? "BW"
        let r = reps.map { "×\($0)" } ?? ""
        let t = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
        return "\(w)\(r)\(t)"
    }
}

@Model
final class Gym {
    var id = UUID()
    var name = ""
    var unavailableExerciseIds = [String]()
    var availableExerciseIds = [String]()
    /// Equipment ids (EquipmentInfo) this gym has at all; empty means anything goes
    var allowedEquipmentIds = [Int]()
    /// Only one dumbbell (home), so two-dumbbell exercises are out
    var singleDumbbell = false
    /// Adjustable dumbbell range: weights are min, min + step, … up to max (e.g. 3, 5.5, 8 … 28)
    var dumbbellMin: Double?
    var dumbbellMax: Double?
    var dumbbellStep: Double?

    init(name: String) {
        self.name = name
    }

    func isAvailable(_ exerciseId: String) -> Bool {
        !unavailableExerciseIds.contains(exerciseId)
    }

    /// Marks plus equipment rules (e.g. home only has one dumbbell)
    func allows(_ exercise: ExerciseDefinition) -> Bool {
        guard isAvailable(exercise.id) else { return false }
        if Self.noGear.contains(exercise.id) { return true }
        if availableExerciseIds.contains(exercise.id) { return true }
        if !allowedEquipmentIds.isEmpty,
           !exercise.equipmentIds.allSatisfy({ allowedEquipmentIds.contains($0) }) {
            return false
        }
        if singleDumbbell, exercise.exerciseType?.hasPrefix("db_2") == true {
            return false
        }
        return true
    }

    /// Stricter than `allows`, for suggestions: once a gym has a confirmed list, only confirmed
    /// exercises are suggested (blank equipment would otherwise allow everything)
    /// Floor ab work needs no equipment, so every gym has it (decline sit-ups and machines don't count)
    static let noGear: Set<String> = [
        "my-plank", "my-side-plank", "my-dead-bug", "my-oblique-crunch", "my-russian-twist", "my-hollow-hold",
        "my-leg-raise-lying", "my-mountain-climber", "my-bicycle-crunch", "my-sit-up", "my-v-up",
    ]

    func suggests(_ exercise: ExerciseDefinition) -> Bool {
        guard allows(exercise) else { return false }
        if Self.noGear.contains(exercise.id) { return true }
        if !availableExerciseIds.isEmpty, allowedEquipmentIds.isEmpty {
            return availableExerciseIds.contains(exercise.id)
        }
        return true
    }

    /// Nearest real dumbbell weight: min + n·step, within [min, max]
    func snapDumbbell(_ weight: Double) -> Double {
        guard let step = dumbbellStep, step > 0 else { return weight }
        let low = dumbbellMin ?? step
        var w = low + ((weight - low) / step).rounded() * step
        w = max(low, w)
        if let high = dumbbellMax { w = min(high, w) }
        return w
    }

    func status(of exerciseId: String) -> GymAvailability {
        if unavailableExerciseIds.contains(exerciseId) { return .missing }
        if availableExerciseIds.contains(exerciseId) { return .confirmed }
        return .unknown
    }

    func setStatus(_ status: GymAvailability, for exerciseId: String) {
        unavailableExerciseIds.removeAll { $0 == exerciseId }
        availableExerciseIds.removeAll { $0 == exerciseId }
        switch status {
        case .missing: unavailableExerciseIds.append(exerciseId)
        case .confirmed: availableExerciseIds.append(exerciseId)
        case .unknown: break
        }
    }
}

enum GymAvailability {
    case confirmed, missing, unknown
}

/// The gym you're currently training at, by name (persisted across launches)
enum CurrentGym {
    static let storageKey = "currentGymName"
}

enum SetTag: String, CaseIterable, Codable {
    case failure
    case badForm = "bad form"
    case pain
    case partial
    case warmup

    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .failure: "xmark.circle"
        case .badForm: "exclamationmark.triangle"
        case .pain: "bolt.fill"
        case .partial: "circle.bottomhalf.filled"
        case .warmup: "flame"
        }
    }
}

extension Double {
    var clean: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", self) : String(format: "%.1f", self)
    }
}
