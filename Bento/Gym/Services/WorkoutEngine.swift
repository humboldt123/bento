import Foundation
import SwiftData

@MainActor
final class WorkoutEngine {

    // MARK: - Heatmap

    struct HeatmapDay: Identifiable {
        let id = UUID()
        let date: Date
        let sets: Int
        let volume: Double

        var intensity: Int {
            if sets == 0 { return 0 }
            if sets <= 6 { return 1 }
            if sets <= 12 { return 2 }
            if sets <= 20 { return 3 }
            return 4
        }
    }

    static func heatmapData(sessions: [WorkoutSession], weeks: Int = 26) -> [HeatmapDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let startDate = calendar.date(byAdding: .weekOfYear, value: -weeks, to: today) else {
            return []
        }

        // Build a map of date -> session stats
        var dayMap: [Date: (sets: Int, volume: Double)] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.date)
            let existing = dayMap[day] ?? (0, 0)
            dayMap[day] = (existing.sets + session.totalSets, existing.volume + session.totalVolume)
        }

        // Generate all days
        var days: [HeatmapDay] = []
        var current = startDate
        while current <= today {
            let stats = dayMap[current]
            days.append(HeatmapDay(date: current, sets: stats?.sets ?? 0, volume: stats?.volume ?? 0))
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86400)
        }
        return days
    }

    // MARK: - Progressive Overload

    struct PRRecord: Identifiable {
        let id = UUID()
        let exerciseId: String
        let exerciseName: String
        let weight: Double
        let reps: Int
        let estimated1RM: Double
        let date: Date
    }

    static func personalRecords(
        sessions: [WorkoutSession],
        exerciseStore: ExerciseStore
    ) -> [PRRecord] {
        var best: [String: PRRecord] = [:]

        for session in sessions {
            for entry in session.entries {
                guard let ex = exerciseStore.exercise(id: entry.exerciseId) else { continue }
                for s in entry.sets {
                    guard let e1rm = s.estimated1RM else { continue }
                    if let current = best[entry.exerciseId] {
                        if e1rm > current.estimated1RM {
                            best[entry.exerciseId] = PRRecord(
                                exerciseId: entry.exerciseId,
                                exerciseName: ex.name,
                                weight: s.weight ?? 0,
                                reps: s.reps ?? 0,
                                estimated1RM: e1rm,
                                date: session.date
                            )
                        }
                    } else {
                        best[entry.exerciseId] = PRRecord(
                            exerciseId: entry.exerciseId,
                            exerciseName: ex.name,
                            weight: s.weight ?? 0,
                            reps: s.reps ?? 0,
                            estimated1RM: e1rm,
                            date: session.date
                        )
                    }
                }
            }
        }

        return best.values.sorted { $0.estimated1RM > $1.estimated1RM }
    }

    /// History of estimated 1RM for a specific exercise over time
    static func exerciseHistory(
        exerciseId: String,
        sessions: [WorkoutSession]
    ) -> [(date: Date, estimated1RM: Double, topWeight: Double, topReps: Int)] {
        sessions
            .sorted { $0.date < $1.date }
            .compactMap { session in
                guard let entry = session.entries.first(where: { $0.exerciseId == exerciseId }) else {
                    return nil
                }
                guard let best = entry.sets.compactMap({ s -> (e1rm: Double, w: Double, r: Int)? in
                    guard let e1rm = s.estimated1RM else { return nil }
                    return (e1rm, s.weight ?? 0, s.reps ?? 0)
                }).max(by: { $0.e1rm < $1.e1rm }) else {
                    return nil
                }
                return (session.date, best.e1rm, best.w, best.r)
            }
    }

    /// Check if a set is a new PR for this exercise
    static func isPR(set: WorkoutSet, exerciseId: String, sessions: [WorkoutSession]) -> Bool {
        guard let newE1rm = set.estimated1RM else { return false }
        let history = exerciseHistory(exerciseId: exerciseId, sessions: sessions)
        let previousBest = history.map(\.estimated1RM).max() ?? 0
        return newE1rm > previousBest
    }

    // MARK: - Muscle Recovery

    struct MuscleRecovery: Identifiable {
        let id: Int
        let muscle: MuscleInfo
        let lastWorked: Date?
        let hoursAgo: Int
        let recoveryPercent: Double

        var isRecovered: Bool { recoveryPercent >= 1.0 }

        var statusColor: String {
            if recoveryPercent >= 1.0 { return "green" }
            if recoveryPercent >= 0.7 { return "yellow" }
            return "red"
        }
    }

    static func muscleRecovery(sessions: [WorkoutSession], exerciseStore: ExerciseStore) -> [MuscleRecovery] {
        let calendar = Calendar.current
        let now = Date.now

        var muscleLastWorked: [Int: Date] = [:]
        for session in sessions {
            for entry in session.entries {
                guard let ex = exerciseStore.exercise(id: entry.exerciseId) else { continue }
                for mid in ex.targetMuscleIds + ex.synergistMuscleIds {
                    if muscleLastWorked[mid] == nil || session.date > muscleLastWorked[mid]! {
                        muscleLastWorked[mid] = session.date
                    }
                }
            }
        }

        return MuscleInfo.allMuscles.compactMap { muscle in
            guard !muscle.frontImages.isEmpty || !muscle.backImages.isEmpty else { return nil }
            let lastWorked = muscleLastWorked[muscle.id]
            let hoursAgo = lastWorked.map {
                calendar.dateComponents([.hour], from: $0, to: now).hour ?? 999
            } ?? 999

            // Simple linear recovery: 0% at 0h, 100% at 72h
            let recoveryHours = 72.0
            let recovery = min(1.0, Double(hoursAgo) / recoveryHours)

            return MuscleRecovery(
                id: muscle.id,
                muscle: muscle,
                lastWorked: lastWorked,
                hoursAgo: hoursAgo,
                recoveryPercent: recovery
            )
        }
    }
}
