import Foundation
import Observation

@MainActor
@Observable
final class ExerciseStore {
    /// False until the (5.7 MB) library finishes loading in the background
    private(set) var isLoaded = false
    /// Your curated exercises (my_exercises.json), used for suggestions and browsing
    private(set) var exercises: [ExerciseDefinition] = []
    /// The full Lyfta library, searchable as a fallback
    private(set) var library: [ExerciseDefinition] = []
    private var byId: [String: ExerciseDefinition] = [:]
    private var searchIndex: [(exercise: ExerciseDefinition, terms: [String], words: [String])] = []

    init() {
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { Self.load() }.value
            exercises = snapshot.exercises
            library = snapshot.library
            byId = snapshot.byId
            searchIndex = snapshot.searchIndex
            isLoaded = true
        }
    }

    func exercise(id: String) -> ExerciseDefinition? {
        byId[id]
    }

    /// Curated matches (name or alias) first, then the rest of the Lyfta library
    func search(_ query: String, limit: Int = 40) -> [ExerciseDefinition] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return exercises }

        var scored: [(exercise: ExerciseDefinition, score: Int)] = []
        for entry in searchIndex {
            var best = 0
            for term in entry.terms {
                if term == q { best = max(best, 100) }
                else if term.hasPrefix(q) { best = max(best, 80) }
                else if term.contains(q) { best = max(best, 60) }
            }
            // A single word of the name ("bench" in "Close-Grip Bench Press") ranks below a real name or alias
            if entry.words.contains(q) { best = max(best, 50) }
            if best > 0 {
                if entry.exercise.isCurated { best += 1000 }
                scored.append((entry.exercise, best))
            }
        }

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.exercise.name < $1.exercise.name }
            .prefix(limit)
            .map(\.exercise)
    }

    /// Curated exercises that target a specific muscle
    func exercises(targeting muscleId: Int) -> [ExerciseDefinition] {
        exercises.filter { $0.targetMuscleIds.contains(muscleId) }
    }

    /// Curated exercises for a body part
    func exercises(bodyPart: Int) -> [ExerciseDefinition] {
        exercises.filter { $0.bodyPartIds.contains(bodyPart) }
    }

    /// Curated exercises in a category (Push, Pull, Legs, Core, ...)
    func exercises(category: String) -> [ExerciseDefinition] {
        exercises.filter { $0.category == category }
    }

    // MARK: - Private

    private struct Snapshot: Sendable {
        var exercises: [ExerciseDefinition] = []
        var library: [ExerciseDefinition] = []
        var byId: [String: ExerciseDefinition] = [:]
        var searchIndex: [(exercise: ExerciseDefinition, terms: [String], words: [String])] = []
    }

    private struct CuratedEntry: Decodable {
        let id: String
        let name: String
        let lyftaId: String
        let category: String
        let mine: Bool
        let aliases: [String]
        let media: String?
        let hasVideo: Bool
        /// Muscle ids replacing Lyfta's where its data is wrong (no biceps on rows and pulldowns,
        /// chest on a chin-up)
        let target: [Int]?
        let helpers: [Int]?

        enum CodingKeys: String, CodingKey {
            case id, name, category, mine, aliases, media, target, helpers
            case lyftaId = "lyfta_id"
            case hasVideo = "has_video"
        }
    }

    nonisolated private static func load() -> Snapshot {
        var snap = Snapshot()

        // Full Lyfta library
        if let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                snap.library = try JSONDecoder().decode([ExerciseDefinition].self, from: data)
                snap.byId = Dictionary(snap.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                print("Failed to decode exercises: \(error)")
            }
        }

        // Curated list, built on top of library entries
        if let url = Bundle.main.url(forResource: "my_exercises", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let entries = try? JSONDecoder().decode([CuratedEntry].self, from: data) {
            snap.exercises = entries.compactMap { entry in
                guard var ex = snap.byId[entry.lyftaId] else { return nil }
                ex.id = entry.id
                ex.name = entry.name
                ex.aliases = entry.aliases
                ex.category = entry.category
                ex.isMine = entry.mine
                ex.isCurated = true
                ex.localMedia = entry.media
                ex.hasLocalVideo = entry.hasVideo
                if let t = entry.target { ex.targetMusclesId = t.map(String.init).joined(separator: ",") }
                if let h = entry.helpers { ex.synergistMusclesId = h.map(String.init).joined(separator: ",") }
                return ex
            }
            for ex in snap.exercises { snap.byId[ex.id] = ex }
        }

        // Search index: curated first, then library entries they don't already cover
        let curatedNames = Set(snap.exercises.flatMap(\.aliases))
        let all = snap.exercises + snap.library.filter {
            !curatedNames.contains($0.name.lowercased().trimmingCharacters(in: .whitespaces))
        }
        snap.searchIndex = all.map { ex in
            let terms = [ex.name.lowercased()] + ex.aliases
            let words = ex.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
            return (ex, terms, words)
        }
        return snap
    }
}
