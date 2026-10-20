import Foundation

/// Minimal Notion REST client for the app's own databases (Decks, Cards, Gym Log, Gyms).
/// The secret and database ids come from Config.xcconfig via Info.plist.
struct NotionAPI {
    enum Failure: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(404, _): "Notion can't see this database. Share the Bento page with the app's connection."
            case .http(let code, let body): "Notion error \(code): \(body.prefix(200))"
            }
        }
    }

    private let secret: String

    init?(bundle: Bundle = .main) {
        guard let secret = bundle.object(forInfoDictionaryKey: "NotionSecret") as? String,
              !secret.isEmpty, !secret.hasPrefix("$(") else { return nil }
        self.secret = secret
    }

    /// Database id from Info.plist ("DecksDatabase", …), nil when not configured
    static func database(_ key: String, bundle: Bundle = .main) -> String? {
        guard let id = bundle.object(forInfoDictionaryKey: key) as? String, !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    /// Every row, following pagination
    func queryAll(_ database: String, sorts: [[String: Any]] = []) async throws -> [Page] {
        var pages: [Page] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if !sorts.isEmpty { body["sorts"] = sorts }
            if let cursor { body["start_cursor"] = cursor }
            let json = try await request("POST", "databases/\(database)/query", body: body)
            pages += (json["results"] as? [[String: Any]] ?? []).compactMap(Page.init)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return pages
    }

    @discardableResult
    func create(in database: String, properties: [String: Any]) async throws -> String {
        let json = try await request("POST", "pages", body: ["parent": ["database_id": database], "properties": properties])
        return json["id"] as? String ?? ""
    }

    func update(page: String, properties: [String: Any]) async throws {
        _ = try await request("PATCH", "pages/\(page)", body: ["properties": properties])
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        // Notion allows ~3 requests/second; back off and retry when rate limited
        for attempt in 0..<4 {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code >= 500, attempt < 3 {
                try await Task.sleep(for: .seconds(Double(attempt + 1)))
                continue
            }
            guard (200..<300).contains(code) else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
            return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        throw Failure.http(429, "rate limited")
    }

    // MARK: - Rows

    /// A database row with typed property readers
    struct Page {
        let id: String
        let properties: [String: Any]

        init?(_ json: [String: Any]) {
            guard let id = json["id"] as? String, let props = json["properties"] as? [String: Any] else { return nil }
            self.id = id
            self.properties = props
        }

        private func prop(_ key: String) -> [String: Any]? { properties[key] as? [String: Any] }

        /// Title or rich text, segments joined
        func text(_ key: String) -> String {
            let p = prop(key)
            let parts = (p?["title"] as? [[String: Any]]) ?? (p?["rich_text"] as? [[String: Any]]) ?? []
            return parts.compactMap { $0["plain_text"] as? String }.joined()
        }

        func number(_ key: String) -> Double? { prop(key)?["number"] as? Double }
        func select(_ key: String) -> String? { (prop(key)?["select"] as? [String: Any])?["name"] as? String }
        func checkbox(_ key: String) -> Bool { prop(key)?["checkbox"] as? Bool ?? false }
        func url(_ key: String) -> String? { prop(key)?["url"] as? String }
        func date(_ key: String) -> Date? {
            guard let start = (prop(key)?["date"] as? [String: Any])?["start"] as? String else { return nil }
            return NotionAPI.parseDate(start)
        }
    }

    // MARK: - Property builders

    static func title(_ s: String) -> [String: Any] { ["title": chunks(s)] }
    static func richText(_ s: String) -> [String: Any] { ["rich_text": chunks(s)] }
    static func number(_ n: Double?) -> [String: Any] { ["number": n as Any? ?? NSNull()] }
    static func select(_ s: String?) -> [String: Any] { ["select": s.map { ["name": $0] } as Any? ?? NSNull()] }
    static func date(_ d: Date?, time: Bool = true) -> [String: Any] {
        guard let d else { return ["date": NSNull()] }
        let s = time ? d.formatted(.iso8601) : d.formatted(.iso8601.year().month().day())
        return ["date": ["start": s]]
    }

    /// Rich text objects hold at most 2000 characters each
    private static func chunks(_ s: String) -> [[String: Any]] {
        guard !s.isEmpty else { return [] }
        var out: [[String: Any]] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            let piece = rest.prefix(1900)
            out.append(["type": "text", "text": ["content": String(piece)]])
            rest = rest.dropFirst(piece.count)
        }
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: s).map { Calendar.current.date(byAdding: .hour, value: 12, to: $0)! }
    }
}
