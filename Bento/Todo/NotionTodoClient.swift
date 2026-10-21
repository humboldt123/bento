import Foundation

/// A row in the Todo Notion database
struct TodoItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var deadline: Date?
    /// True when the deadline has a time, not just a day
    var hasTime: Bool
    var status: String
    var type: String?
    /// Course name (or other text) from "Associated With"
    var course: String?
    /// The linked course page, when "Associated With" mentions one
    var coursePageId: String?
    var url: URL?

    var isInProgress: Bool { status.hasPrefix("in progres") }
}

/// Status options in the Notion database, in menu order
enum TodoStatus: String, CaseIterable {
    case todo = "todo"
    case inProgress = "in progres..."
    case done = "done"
    case late = "late"
    case doneImproperly = "done improperly"
    case wontDo = "wont do"

    var label: String {
        switch self {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        case .late: "Done late"
        case .doneImproperly: "Done improperly"
        case .wontDo: "Won't do"
        }
    }

    var symbol: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .late: "clock.badge.checkmark"
        case .doneImproperly: "checkmark.circle.trianglebadge.exclamationmark"
        case .wontDo: "xmark.circle"
        }
    }

    /// Statuses that take a task off the open list
    var isClosed: Bool { self != .todo && self != .inProgress }
}

/// One block of a Notion page, flattened for rendering
struct NotionBlock: Sendable {
    let type: String
    /// Raw rich_text (or equation/caption) payload, kept as JSON-ish dictionaries
    let payload: [String: any Sendable]
    var children: [NotionBlock] = []
}

/// Talks to the Notion API for the Todo database. Credentials come from Config.xcconfig via Info.plist.
struct NotionTodoClient: Sendable {
    enum ClientError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Notion isn't set up. Fill in NOTION_SECRET and TODO_DB in Config.xcconfig and rebuild."
            case .http(let code, let body):
                "Notion returned \(code): \(body.prefix(200))"
            }
        }
    }

    static let types = ["School", "Personal", "Work"]

    private let secret: String
    private let databaseId: String

    init?(bundle: Bundle = .main) {
        guard let secret = bundle.object(forInfoDictionaryKey: "NotionSecret") as? String,
              let db = bundle.object(forInfoDictionaryKey: "TodoDatabase") as? String,
              !secret.isEmpty, !db.isEmpty, !secret.hasPrefix("$(") else { return nil }
        self.secret = secret
        self.databaseId = db
    }

    /// Everything still to do or in progress, soonest deadline first
    func openItems() async throws -> [TodoItem] {
        var items: [TodoItem] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "filter": ["or": [
                    ["property": "Status", "status": ["equals": "todo"]],
                    ["property": "Status", "status": ["equals": "in progres..."]],
                ]],
                "sorts": [["property": "Deadline", "direction": "ascending"]],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await request("POST", "databases/\(databaseId)/query", body: body)
            let results = json["results"] as? [[String: Any]] ?? []
            items += results.compactMap(Self.item)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return items
    }

    /// "PHYS 232" for a course page, read from the Courses database's "Course Code"
    func courseCode(pageId: String) async -> String? {
        guard let json = try? await request("GET", "pages/\(pageId)", body: nil),
              let props = json["properties"] as? [String: Any],
              let code = props["Course Code"] as? [String: Any] else { return nil }
        let parts = (code["rich_text"] as? [[String: Any]]) ?? (code["title"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// The page body (blocks), with children of toggles/lists one level deep
    func blocks(pageId: String, depth: Int = 0) async throws -> [NotionBlock] {
        var result: [NotionBlock] = []
        var cursor: String?
        repeat {
            var path = "blocks/\(pageId)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let json = try await request("GET", path, body: nil)
            for raw in json["results"] as? [[String: Any]] ?? [] {
                guard let type = raw["type"] as? String else { continue }
                let payload = (raw[type] as? [String: Any]) ?? [:]
                var block = NotionBlock(type: type, payload: Self.sendable(payload) as? [String: any Sendable] ?? [:])
                if raw["has_children"] as? Bool == true, depth < 2, type != "child_page", type != "child_database",
                   let id = raw["id"] as? String {
                    block.children = (try? await blocks(pageId: id, depth: depth + 1)) ?? []
                }
                result.append(block)
            }
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return result
    }

    /// JSON from JSONSerialization is all value types underneath; this makes that explicit for Sendable
    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let d as [String: Any]: return d.filter { !($0.value is NSNull) }.mapValues { sendable($0) }
        case let a as [Any]: return a.filter { !($0 is NSNull) }.map { sendable($0) }
        case let s as String: return s
        case let n as NSNumber: return n.doubleValue
        default: return String(describing: value)
        }
    }

    func setStatus(_ status: String, for id: String) async throws {
        _ = try await request("PATCH", "pages/\(id)", body: [
            "properties": ["Status": ["status": ["name": status]]],
        ])
    }

    func add(name: String, type: String, deadline: Date?, course: String?) async throws {
        var properties: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]],
            "Type": ["select": ["name": type]],
            "Status": ["status": ["name": "todo"]],
        ]
        if let deadline {
            properties["Deadline"] = ["date": ["start": Self.dayFormatter.string(from: deadline)]]
        }
        if let course, !course.isEmpty {
            properties["Associated With"] = ["rich_text": [["text": ["content": course]]]]
        }
        _ = try await request("POST", "pages", body: [
            "parent": ["database_id": databaseId],
            "properties": properties,
        ])
    }

    // MARK: - Private

    private func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        #if targetEnvironment(simulator)
        if method != "GET" && !path.hasSuffix("/query") { return [:] }
        #endif
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func item(_ page: [String: Any]) -> TodoItem? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }

        func text(_ key: String, _ kind: String) -> String? {
            let parts = (props[key] as? [String: Any])?[kind] as? [[String: Any]] ?? []
            let joined = parts.compactMap { $0["plain_text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        let dateStart = ((props["Deadline"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
        let status = (((props["Status"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String) ?? "todo"
        let type = ((props["Type"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String

        // "Associated With" is usually a mention of a course page; a few rows hold a bare page id
        let assoc = (props["Associated With"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
        var coursePageId = assoc.lazy.compactMap { (($0["mention"] as? [String: Any])?["page"] as? [String: Any])?["id"] as? String }.first
        var course = text("Associated With", "rich_text")
        if let raw = course, raw.wholeMatch(of: /[0-9a-f]{32}/) != nil {
            coursePageId = raw
            course = nil
        }

        return TodoItem(
            id: id,
            name: text("Name", "title") ?? "Untitled",
            deadline: dateStart.flatMap(parseDate),
            hasTime: dateStart.map { $0.contains("T") } ?? false,
            status: status,
            type: type,
            course: course,
            coursePageId: coursePageId,
            url: (page["url"] as? String).flatMap(URL.init(string:))
        )
    }

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if s.count == 10 {
            // All-day: end of that day, so "due today" isn't overdue at 12:01am
            return dayFormatter.date(from: s).flatMap {
                Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: $0)
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
