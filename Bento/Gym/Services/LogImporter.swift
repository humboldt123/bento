import Foundation
import SwiftData

/// Parses workout notes, either a quick notes format:
///
///     7.8
///     - bench-85:10,85:8,85:8
///     - dumbbell curl-25:8,25:9(attempted 10, failed on left)
///
/// or what `export` writes:
///
///     2026-10-15 · Pull · My Gym
///     - Lat Pulldown: 70×12, 85×11, 85×8
///
/// Weights are lb.
@MainActor
enum LogImporter {
    struct ParsedSet {
        var weight: Double
        var reps: Int
        var note: String?
    }

    struct ParsedEntry {
        var rawName: String
        var exercise: ExerciseDefinition?
        var sets: [ParsedSet]
    }

    struct ParsedDay {
        var date: Date
        var entries: [ParsedEntry]
        /// Exercises noted as skipped, e.g. "(seated row and rear delt skipped: machines taken)"
        var skipped: [ExerciseDefinition] = []
        /// From an exported header line ("2026-10-15 · Pull · My Gym")
        var gymName: String?
    }

    static func parse(_ text: String, store: ExerciseStore, now: Date = .now) -> [ParsedDay] {
        var days: [ParsedDay] = []
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // "10.15" or "10.15 pull"
            let firstToken = line.split(separator: " ").first.map(String.init) ?? line
            if let date = parseDate(firstToken, year: year, now: now, calendar: calendar) {
                let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                days.append(ParsedDay(date: date, entries: [], gymName: parts.count >= 3 ? parts[2] : nil))
                continue
            }

            if line.hasPrefix("("), line.lowercased().contains("skip"), !days.isEmpty {
                days[days.count - 1].skipped += parseSkipped(line, store: store)
                continue
            }

            guard line.hasPrefix("-"), !days.isEmpty else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // Name is everything before the first "-" or ":" that's followed by a number
            guard let dash = body.firstRange(of: /[-:]\s*\d/) else { continue }
            let fullName = String(body[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            // "lat pulldown (Matrix)" -> "lat pulldown", unless it's an exact name like "Shrug (Barbell)"
            let name = fullName.replacing(/\(.*?\)/, with: "").trimmingCharacters(in: .whitespaces)
            let setsText = String(body[body.index(after: dash.lowerBound)...])

            let exercise = store.exercises.first { $0.name.caseInsensitiveCompare(fullName) == .orderedSame }
                ?? store.search(name, limit: 1).first
            days[days.count - 1].entries.append(
                ParsedEntry(rawName: name, exercise: exercise, sets: parseSets(setsText))
            )
        }
        return days.filter { !$0.entries.isEmpty || !$0.skipped.isEmpty }
    }

    /// Inserts parsed days as sessions, skipping days that already have a session
    @discardableResult
    static func insert(_ days: [ParsedDay], gymName: String?, into context: ModelContext, existing: [WorkoutSession]) -> Int {
        let calendar = Calendar.current
        let loggedDays = Set(existing.map { calendar.startOfDay(for: $0.date) })
        var gyms = (try? context.fetch(FetchDescriptor<Gym>())) ?? []
        var count = 0

        // A day already here (e.g. a workout planned on this device) still takes sets logged elsewhere:
        // remote sets fill in sets that are only planned here, never overwrite ones you did, and
        // exercises missing here are added
        for day in days where loggedDays.contains(calendar.startOfDay(for: day.date)) {
            guard let session = existing.first(where: { calendar.isDate($0.date, inSameDayAs: day.date) }) else { continue }
            for parsed in day.entries {
                guard let ex = parsed.exercise else { continue }
                // An exercise logged elsewhere (or added in Notion) joins the day
                guard let entry = session.entries.first(where: { $0.exerciseId == ex.id }) else {
                    let entry = WorkoutEntry(exerciseId: ex.id, order: session.entries.count)
                    session.entries.append(entry)
                    for (j, s) in parsed.sets.enumerated() { entry.sets.append(WorkoutSet(order: j, weight: s.weight, reps: s.reps)) }
                    continue
                }
                let done = entry.sets.filter { !$0.isPlanned }.count
                guard parsed.sets.count > done else { continue }
                let planned = entry.sets.filter(\.isPlanned).sorted { $0.order < $1.order }
                for (k, remote) in parsed.sets.dropFirst(done).enumerated() {
                    if k < planned.count {
                        planned[k].weight = remote.weight
                        planned[k].reps = remote.reps
                        planned[k].isPlanned = false
                    } else {
                        entry.sets.append(WorkoutSet(order: entry.sets.count, weight: remote.weight, reps: remote.reps))
                    }
                }
            }
        }

        for day in days where !loggedDays.contains(calendar.startOfDay(for: day.date)) {
            let dayGym = day.gymName ?? gymName
            if let dayGym, !gyms.contains(where: { $0.name == dayGym }) {
                let gym = Gym(name: dayGym)
                context.insert(gym)
                gyms.append(gym)
            }
            let session = WorkoutSession(date: day.date, gymName: dayGym)
            context.insert(session)
            for (i, parsed) in day.entries.enumerated() {
                guard let ex = parsed.exercise else { continue }
                let entry = WorkoutEntry(exerciseId: ex.id, order: i)
                session.entries.append(entry)
                for (j, s) in parsed.sets.enumerated() {
                    let set = WorkoutSet(order: j, weight: s.weight, reps: s.reps)
                    if let note = s.note {
                        set.note = note
                        if note.lowercased().contains("fail") { set.tags.append(SetTag.failure.rawValue) }
                    }
                    entry.sets.append(set)
                }
            }
            count += 1
        }
        for day in days where !day.skipped.isEmpty {
            CarryOver.add(day.skipped.map(\.id), on: day.date)
        }
        return count
    }

    // MARK: - Private

    /// "(seated row and rear delt skipped: machines taken)" -> [Low Row Machine, Reverse Fly Machine]
    private static func parseSkipped(_ line: String, store: ExerciseStore) -> [ExerciseDefinition] {
        var text = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        text = text.replacing(/\bskipped\b|\bskip\b/, with: "")
        return text
            .replacing(" and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { store.search($0, limit: 1).first }
            .filter(\.isCurated)
    }

    private static func parseDate(_ line: String, year: Int, now: Date, calendar: Calendar) -> Date? {
        if let iso = line.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/) {
            return calendar.date(from: DateComponents(year: Int(iso.1), month: Int(iso.2), day: Int(iso.3), hour: 12))
        }
        guard let match = line.wholeMatch(of: /(\d{1,2})[.\/](\d{1,2})(?:[.\/](\d{2,4}))?/) else { return nil }
        let month = Int(match.1)!, day = Int(match.2)!
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var y = match.3.flatMap { Int($0) } ?? year
        if y < 100 { y += 2000 }
        // Noon so time zone shifts never move it to another day
        var date = calendar.date(from: DateComponents(year: y, month: month, day: day, hour: 12))
        if match.3 == nil, let d = date, d > now {
            date = calendar.date(byAdding: .year, value: -1, to: d)
        }
        return date
    }

    private static func parseSets(_ text: String) -> [ParsedSet] {
        // Pull out "(notes)" first since they can contain commas; attach to the set before them
        var notes: [Int: String] = [:]
        var cleaned = ""
        var depth = 0
        var current = ""
        for ch in text {
            if ch == "(" { depth += 1; if depth == 1 { current = ""; continue } }
            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    let setIndex = cleaned.components(separatedBy: ",").count - 1
                    notes[setIndex] = current.trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            if depth > 0 { current.append(ch) } else { cleaned.append(ch) }
        }

        // Tokens are numbers; anything else (":", "×", ",", "x") separates them. Typos like "50;10" or "40,10" still pair up.
        let numbers = cleaned
            .split(whereSeparator: { !($0.isNumber || $0 == ".") })
            .compactMap { Double($0) }
        var sets: [ParsedSet] = []
        var i = 0
        while i + 1 < numbers.count {
            sets.append(ParsedSet(weight: numbers[i], reps: Int(numbers[i + 1])))
            i += 2
        }
        for (index, note) in notes where index < sets.count {
            sets[index].note = note
        }
        return sets
    }

    // MARK: - Export

    /// Oldest first, in the format `parse` reads back
    static func export(_ sessions: [WorkoutSession], store: ExerciseStore) -> String {
        sessions.sorted { $0.date < $1.date }.map { session in
            var header = [session.date.formatted(.iso8601.year().month().day())]
            if let split = split(of: session, store: store) { header.append(split) }
            if let gym = session.gymName {
                if header.count == 1 { header.append("Workout") }
                header.append(gym)
            }
            var lines = [header.joined(separator: " · ")]
            for entry in session.sortedEntries {
                let name = store.exercise(id: entry.exerciseId)?.name ?? entry.exerciseId
                // Only sets actually done; planned targets are not a workout
                let sets = entry.sortedSets.compactMap { set -> String? in
                    guard !set.isPlanned, let w = set.weight, let r = set.reps else { return nil }
                    let note = set.note ?? (set.tags.isEmpty ? nil : set.tags.joined(separator: ", "))
                    return "\(w.clean)×\(r)" + (note.map { " (\($0))" } ?? "")
                }
                guard !sets.isEmpty else { continue }
                lines.append("- \(name): \(sets.joined(separator: ", "))")
                if let note = entry.note { lines.append("  Note: \(note)") }
            }
            if let note = session.notes { lines.append("Note: \(note)") }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func split(of session: WorkoutSession, store: ExerciseStore) -> String? {
        let mapping = ["Push": "Push", "Pull": "Pull", "Forearms": "Pull", "Legs": "Legs", "Back / Lower Back": "Legs"]
        let splits = session.entries.compactMap { store.exercise(id: $0.exerciseId)?.category.flatMap { mapping[$0] } }
        let counts = Dictionary(grouping: splits, by: { $0 }).mapValues(\.count)
        guard let top = counts.values.max() else { return nil }
        // Ties (curls + pushdowns) read as "Pull + Push"
        return counts.filter { $0.value == top }.keys.sorted().joined(separator: " + ")
    }
}
