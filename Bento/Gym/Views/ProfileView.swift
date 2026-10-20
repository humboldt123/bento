import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(ExerciseStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @AppStorage("userName") private var userName = ""
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""

    private var prs: [WorkoutEngine.PRRecord] {
        WorkoutEngine.personalRecords(sessions: Array(sessions), exerciseStore: store)
    }

    private var streak: Int {
        let calendar = Calendar.current
        var count = 0
        var checkDate = calendar.startOfDay(for: .now)

        // Check if today has a workout, if not start from yesterday
        let todaySession = sessions.first { calendar.isDateInToday($0.date) }
        if todaySession == nil {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        let sessionDates = Set(sessions.map { calendar.startOfDay(for: $0.date) })

        while sessionDates.contains(checkDate) {
            count += 1
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        return count
    }

    private var thisMonthCount: Int {
        let calendar = Calendar.current
        return sessions.filter {
            calendar.isDate($0.date, equalTo: .now, toGranularity: .month)
        }.count
    }

    private var firstSessionDate: Date? {
        sessions.last?.date
    }

    var body: some View {
        NavigationStack {
            List {
                // Stats
                Section {
                    HStack(spacing: 12) {
                        StatBox(title: "Streak", value: "\(streak)", unit: "days", icon: "flame.fill", color: .orange)
                        StatBox(title: "This Month", value: "\(thisMonthCount)", unit: "sessions", icon: "calendar", color: .blue)
                        StatBox(title: "Total", value: "\(sessions.count)", unit: "workouts", icon: "figure.strengthtraining.traditional", color: .green)
                    }
                    .padding(.trailing, 3)
                    .padding(.bottom, 3)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // PRs
                Section("Personal Records") {
                    if prs.isEmpty {
                        Text("No PRs yet — start logging!")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(prs.prefix(10)) { pr in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pr.exerciseName)
                                        .font(.subheadline.bold())
                                    Text("\(pr.weight.clean) lb × \(pr.reps)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("e1RM: \(pr.estimated1RM.clean) lb")
                                        .font(.caption.bold())
                                    Text(pr.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Gyms
                Section("Gyms") {
                    ForEach(gyms) { gym in
                        Button {
                            currentGymName = gym.name
                        } label: {
                            HStack {
                                GymBadge(name: gym.name, size: 22)
                                    .frame(width: 32)
                                Text(gym.name)
                                    .foregroundStyle(.primary)
                                if gym.name == currentGymName {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                }
                                Spacer()
                                Text("\(gym.availableExerciseIds.count) here · \(gym.unavailableExerciseIds.count) missing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            if gyms[i].name == currentGymName { currentGymName = "" }
                            modelContext.delete(gyms[i])
                        }
                    }
                    AddGymButton()
                }

                // Settings
                Section("Settings") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Your name", text: $userName)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        ImportLogView()
                    } label: {
                        Label("Import from notes", systemImage: "square.and.arrow.down")
                    }

                    ShareLink(item: LogImporter.export(Array(sessions), store: store)) {
                        Label("Export log as text", systemImage: "square.and.arrow.up")
                    }
                    .disabled(sessions.isEmpty)

                    if let first = firstSessionDate {
                        HStack {
                            Text("Training since")
                            Spacer()
                            Text(first, format: .dateTime.month(.wide).year())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .bentoScreen()
            .navigationTitle(userName.isEmpty ? "You" : userName)
            .bentoCloseButton()
        }
    }
}

// MARK: - Stat Box

struct StatBox: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .bentoCard(cornerRadius: 18)
    }
}

// MARK: - Add Gym Button

struct AddGymButton: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showAlert = false
    @State private var gymName = ""
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""

    var body: some View {
        Button {
            showAlert = true
        } label: {
            Label("Add Gym", systemImage: "plus.circle")
        }
        .alert("New Gym", isPresented: $showAlert) {
            TextField("Gym name", text: $gymName)
            Button("Add") {
                guard !gymName.isEmpty else { return }
                let gym = Gym(name: gymName)
                modelContext.insert(gym)
                currentGymName = gymName
                gymName = ""
            }
            Button("Cancel", role: .cancel) { gymName = "" }
        }
    }
}

// MARK: - Import Log

struct ImportLogView: View {
    @Environment(ExerciseStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [WorkoutSession]
    @Query(sort: \Gym.name) private var gyms: [Gym]

    @State private var text = ""
    /// Old notes are often from a different gym than the current one, so this starts empty
    @State private var importGym = ""
    @State private var imported: Int?

    private var parsed: [LogImporter.ParsedDay] {
        LogImporter.parse(text, store: store)
    }

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
            } header: {
                Text("Paste notes")
            } footer: {
                Text("Paste old notes (\"7.8\" then \"- bench-85:10,85:8\") or a Bento export. Weights in lb.")
            }

            if !parsed.isEmpty {
                Section("Preview") {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { _, day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.date, format: .dateTime.month(.abbreviated).day().year())
                                .font(.subheadline.bold())
                            ForEach(Array(day.entries.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.exercise?.name ?? "? \(entry.rawName)")
                                        .foregroundStyle(entry.exercise == nil ? .red : .primary)
                                    Spacer()
                                    Text(entry.sets.map { "\($0.weight.clean)×\($0.reps)" }.joined(separator: " "))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            if !day.skipped.isEmpty {
                                Text("Skipped, do first next time: \(day.skipped.map(\.name).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Gym")
                        TextField("Gym (optional)", text: $importGym)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Import \(parsed.count) days") {
                        let gymName = importGym.trimmingCharacters(in: .whitespaces)
                        if !gymName.isEmpty, !gyms.contains(where: { $0.name == gymName }) {
                            modelContext.insert(Gym(name: gymName))
                        }
                        imported = LogImporter.insert(
                            parsed,
                            gymName: gymName.isEmpty ? nil : gymName,
                            into: modelContext,
                            existing: sessions
                        )
                    }
                    .disabled(imported != nil)
                } footer: {
                    if let imported {
                        Text("Imported \(imported) days. Days you already logged were skipped.")
                    }
                }
            }
        }
        .bentoScreen()
        .navigationTitle("Import")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sample") { text = Self.sample }
            }
        }
    }

    /// Example of the notes format the importer reads
    static let sample = """
    7.8
    - bench-85:10,85:8,85:8
    - leg press-200:12,220:12
    7.6
    - dumbbell curl-25:8,25:10(failed on left)
    - low row-90:12,90:12
    """
}
