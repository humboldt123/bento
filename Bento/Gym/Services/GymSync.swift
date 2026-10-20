import SwiftUI
import SwiftData

/// Gyms and workout history live in Notion (Bento › Gyms › Locations and Gym Log). Gyms are pulled into
/// SwiftData; workouts sync both ways, one Gym Log row per day in the export format.
@MainActor
enum GymSync {
    /// Gym name -> its "Logo" value (an asset name or an image URL), for GymBadge
    static let logosKey = "gymLogos"
    /// Gyms with a single dumbbell, shown with a house
    static let homesKey = "homeGyms"

    static func run(store: ExerciseStore, context: ModelContext) async {
        guard let api = NotionAPI() else { return }
        while !store.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        if let db = NotionAPI.database("GymsDatabase") { await pullGyms(api, db, context) }
        if let db = NotionAPI.database("GymLogDatabase") { await syncLog(api, db, store, context) }
    }

    /// Creates or updates local gyms from the Gyms database
    private static func pullGyms(_ api: NotionAPI, _ db: String, _ context: ModelContext) async {
        guard let rows = try? await api.queryAll(db, sorts: [["property": "Order", "direction": "ascending"]]) else { return }
        let existing = (try? context.fetch(FetchDescriptor<Gym>())) ?? []
        var logos: [String: String] = [:]
        var homes: [String] = []
        func ids(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        for row in rows {
            let name = row.text("Name")
            guard !name.isEmpty else { continue }
            let gym = existing.first { $0.name == name } ?? { let g = Gym(name: name); context.insert(g); return g }()
            gym.availableExerciseIds = Array(Set(gym.availableExerciseIds + ids(row.text("Exercises"))))
            gym.allowedEquipmentIds = ids(row.text("Equipment")).compactMap { Int($0) }
            gym.singleDumbbell = row.checkbox("Single Dumbbell")
            gym.dumbbellMin = row.number("Dumbbell Min")
            gym.dumbbellMax = row.number("Dumbbell Max")
            gym.dumbbellStep = row.number("Dumbbell Step")
            if let logo = row.url("Logo") ?? Optional(row.text("Logo")), !logo.isEmpty { logos[name] = logo }
            if gym.singleDumbbell { homes.append(name) }
            if row.checkbox("Default"), (UserDefaults.standard.string(forKey: CurrentGym.storageKey) ?? "").isEmpty {
                UserDefaults.standard.set(name, forKey: CurrentGym.storageKey)
            }
        }
        UserDefaults.standard.set(logos, forKey: logosKey)
        UserDefaults.standard.set(homes, forKey: homesKey)
    }

    /// Pulls days that aren't here yet, then writes local days that are missing or different in Notion.
    /// A row is Split (title, e.g. "Pull"), Date, Gym and Exercises (the "- Name: 70×12, …" lines).
    private static func syncLog(_ api: NotionAPI, _ db: String, _ store: ExerciseStore, _ context: ModelContext) async {
        guard let rows = try? await api.queryAll(db) else { return }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"

        var remote: [String: (page: String, log: String)] = [:]
        for row in rows {
            guard let date = row.date("Date") else { continue }
            let key = day.string(from: date)
            let header = [key, row.text("Split").isEmpty ? "Workout" : row.text("Split"), row.select("Gym")]
                .compactMap { $0 }.joined(separator: " · ")
            remote[key] = (row.id, header + "\n" + row.text("Exercises"))
        }

        let existing = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let days = LogImporter.parse(remote.values.map(\.log).joined(separator: "\n\n"), store: store)
        LogImporter.insert(days, gymName: nil, into: context, existing: existing)
        try? context.save()

        let sessions = ((try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []).filter(\.isLogged)
        for session in sessions {
            let log = LogImporter.export([session], store: store)
            let key = String(log.prefix(10))
            if remote[key]?.log == log { continue }
            var lines = log.components(separatedBy: "\n")
            let header = lines.removeFirst().components(separatedBy: " · ")
            let props: [String: Any] = [
                "Split": NotionAPI.title(header.count > 1 ? header[1] : "Workout"),
                "Date": NotionAPI.date(session.date, time: false),
                "Gym": NotionAPI.select(session.gymName),
                "Exercises": NotionAPI.richText(lines.joined(separator: "\n")),
            ]
            if let page = remote[key]?.page {
                try? await api.update(page: page, properties: props)
            } else {
                try? await api.create(in: db, properties: props)
            }
        }
    }
}

/// Small logo next to a gym's name: the gym's "Logo" from Notion (asset name or URL), a house for
/// a one-dumbbell home gym, else a pin
struct GymBadge: View {
    let name: String?
    var size: CGFloat = 18

    var body: some View {
        let logo = name.flatMap { (UserDefaults.standard.dictionary(forKey: GymSync.logosKey) as? [String: String])?[$0] }
        let isHome = name.map { (UserDefaults.standard.stringArray(forKey: GymSync.homesKey) ?? []).contains($0) } ?? false
        if let logo, logo.hasPrefix("http"), let url = URL(string: logo) {
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: size * 1.6, height: size)
        } else if let logo, UIImage(named: logo) != nil {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: size * 1.6, maxHeight: size)
                .foregroundStyle(.gray)
        } else {
            Image(systemName: isHome ? "house.fill" : "mappin")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
        }
    }
}
