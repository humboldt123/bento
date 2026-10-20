import SwiftUI
import Observation

/// Course page id -> "PHYS 232", looked up once per course and kept across launches
@MainActor
@Observable
final class CourseCodes {
    static let shared = CourseCodes()

    private static let key = "courseCodes"
    private(set) var codes: [String: String]
    private var inFlight: Set<String> = []

    private init() {
        codes = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Short label for a task's course: the code if known, else the name Notion gave us
    func label(for item: TodoItem) -> String? {
        if let id = item.coursePageId.map(Self.normalize), let code = codes[id] { return code }
        return item.course
    }

    func resolve(_ items: [TodoItem], client: NotionTodoClient) async {
        let missing = Set(items.compactMap { $0.coursePageId.map(Self.normalize) })
            .subtracting(codes.keys)
            .subtracting(inFlight)
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing)
        await withTaskGroup(of: (String, String?).self) { group in
            for id in missing {
                group.addTask { (id, await client.courseCode(pageId: id)) }
            }
            for await (id, code) in group {
                if let code { codes[id] = code }
            }
        }
        inFlight.subtract(missing)
        UserDefaults.standard.set(codes, forKey: Self.key)
    }

    /// Notion hands out ids with and without dashes
    private static func normalize(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Tasks closed in the app recently. Notion's query lags edits by a few seconds,
/// so these stay hidden until it catches up.
@MainActor
enum RecentlyClosed {
    private static let key = "recentlyClosedTasks"
    private static let ttl: TimeInterval = 15 * 60

    static func add(_ id: String) {
        var all = current()
        all[id] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: key)
    }

    static func remove(_ id: String) {
        var all = current()
        all[id] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    static func filter(_ items: [TodoItem]) -> [TodoItem] {
        let closed = current()
        return items.filter { closed[$0.id] == nil }
    }

    private static func current() -> [String: Double] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let cutoff = Date.now.timeIntervalSince1970 - ttl
        return raw.filter { $0.value > cutoff }
    }
}

/// One color per course, so chips are a rainbow instead of all pink
enum CourseColors {
    private static let palette: [Color] = [.red, .orange, .green, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]

    static func color(for label: String) -> Color {
        // Stable across launches (String.hashValue isn't)
        let sum = label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }

}
