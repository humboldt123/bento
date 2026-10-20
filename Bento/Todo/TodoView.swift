import SwiftUI

struct TodoView: View {
    @State private var items: [TodoItem] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var showAdd = false
    @State private var typeFilter: String?
    @State private var showLongTerm = false

    private let client = NotionTodoClient()
    private let codes = CourseCodes.shared

    /// Anything due further out than this goes in "Future"
    private static let horizonDays = 14

    private var visible: [TodoItem] {
        items.filter { typeFilter == nil || $0.type == typeFilter }
    }

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let isOverdue: Bool
        let items: [TodoItem]
    }

    private var longTerm: [TodoItem] {
        let horizon = Calendar.current.date(byAdding: .day, value: Self.horizonDays, to: Calendar.current.startOfDay(for: .now))!
        return visible.filter { ($0.deadline ?? .distantPast) >= horizon }
    }

    private var noDate: [TodoItem] { visible.filter { $0.deadline == nil } }

    /// Overdue, Today, Tomorrow, then one section per day up to the horizon
    private var daySections: [DaySection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let horizon = cal.date(byAdding: .day, value: Self.horizonDays, to: today)!
        let dated = visible.filter { ($0.deadline ?? .distantFuture) < horizon }

        var sections: [DaySection] = []
        let overdue = dated.filter { $0.deadline! < today }
        if !overdue.isEmpty {
            sections.append(DaySection(id: "overdue", title: "Overdue", isOverdue: true, items: overdue))
        }
        let upcoming = Dictionary(grouping: dated.filter { $0.deadline! >= today }) { cal.startOfDay(for: $0.deadline!) }
        for day in upcoming.keys.sorted() {
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInTomorrow(day) { title = "Tomorrow" }
            else { title = day.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
            sections.append(DaySection(id: day.description, title: title, isOverdue: false, items: upcoming[day]!))
        }
        return sections
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                ForEach(daySections) { section in
                    Section {
                        ForEach(section.items) { row($0, showDate: section.isOverdue) }
                    } header: {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(section.isOverdue ? .red : .primary)
                            .textCase(nil)
                    }
                }

                if !noDate.isEmpty {
                    Section("No date") {
                        ForEach(noDate) { row($0, showDate: false) }
                    }
                }

                if !longTerm.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showLongTerm) {
                            ForEach(longTerm) { row($0, showDate: true) }
                        } label: {
                            Label("Future · \(longTerm.count)", systemImage: "calendar.badge.clock")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                if client != nil {
                    Section {
                        Button {
                            showAdd = true
                        } label: {
                            Label("New task", systemImage: "plus.circle")
                        }
                    }
                }

                if !isLoading, error == nil, visible.isEmpty {
                    ContentUnavailableView("All clear", systemImage: "checkmark.circle", description: Text("Nothing open in Notion."))
                }
            }
            .listStyle(.insetGrouped)
            .bentoScreen()
            .overlay {
                if isLoading && items.isEmpty { ProgressView() }
            }
            .refreshable { await load() }
            .navigationTitle("tasks")
            .bentoCloseButton()
            .navigationDestination(for: TodoItem.self) { item in
                TaskDetailView(item: item, client: client) { status in
                    await setStatus(status, item)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $typeFilter) {
                            Text("All").tag(String?.none)
                            ForEach(NotionTodoClient.types, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Image(systemName: typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(client == nil)
                }
            }
            .sheet(isPresented: $showAdd) {
                AddTodoView { name, type, deadline, course in
                    try await client?.add(name: name, type: type, deadline: deadline, course: course)
                    await load()
                }
            }
            .task { await load() }
        }
    }

    private func row(_ item: TodoItem, showDate: Bool) -> some View {
        NavigationLink(value: item) {
            TaskRow(item: item, course: codes.label(for: item), showDate: showDate)
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await setStatus(.done, item) }
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(.green)
            Button {
                Task { await setStatus(.wontDo, item) }
            } label: {
                Label("Won't do", systemImage: "xmark")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if !item.isInProgress {
                Button {
                    Task { await setStatus(.inProgress, item) }
                } label: {
                    Label("Start", systemImage: "play")
                }
                .tint(.blue)
            }
        }
    }

    private func load() async {
        guard let client else {
            error = NotionTodoClient.ClientError.notConfigured.errorDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            items = RecentlyClosed.filter(try await client.openItems())
            error = nil
            await codes.resolve(items, client: client)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setStatus(_ status: TodoStatus, _ item: TodoItem) async {
        guard let client else { return }
        let previous = items
        if status.isClosed {
            RecentlyClosed.add(item.id)
            items.removeAll { $0.id == item.id }
        } else if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].status = status.rawValue
        }
        do {
            try await client.setStatus(status.rawValue, for: item.id)
        } catch {
            RecentlyClosed.remove(item.id)
            items = previous
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

struct TaskRow: View {
    let item: TodoItem
    let course: String?
    let showDate: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.isInProgress ? "circle.lefthalf.filled" : "circle")
                .font(.caption)
                .foregroundStyle(item.isInProgress ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                if course != nil || showDate || item.hasTime {
                    HStack(spacing: 6) {
                        if let course {
                            Text(course)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(CourseColors.color(for: course).opacity(0.18), in: Capsule())
                                .foregroundStyle(CourseColors.color(for: course))
                        }
                        if let deadline = item.deadline, showDate || item.hasTime {
                            Text(dateText(deadline))
                                .font(.caption)
                                .foregroundStyle(deadline < .now ? .red : .secondary)
                        }
                    }
                }
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        let time = item.hasTime ? date.formatted(date: .omitted, time: .shortened) : ""
        guard showDate else { return time }
        let cal = Calendar.current
        if date < .now && !cal.isDateInToday(date) {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day ?? 0
            return days == 1 ? "yesterday" : "\(days) days late"
        }
        return date.formatted(.dateTime.month(.abbreviated).day()) + (time.isEmpty ? "" : " " + time)
    }
}

enum TaskColors {
    static func color(for type: String?) -> Color {
        switch type {
        case "School": .pink
        case "Work": .orange
        case "Personal": .brown
        default: .gray
        }
    }
}

// MARK: - Add

struct AddTodoView: View {
    let onAdd: (String, String, Date?, String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "School"
    @State private var hasDeadline = true
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    @State private var course = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("What needs doing?", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(NotionTodoClient.types, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Deadline", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("Due", selection: $deadline, displayedComponents: .date)
                }
                if type == "School" {
                    TextField("Course (e.g. MATH 410)", text: $course)
                        .textInputAutocapitalization(.characters)
                    // Courses Bento has seen on your tasks, one tap to fill in
                    let known = Array(Set(CourseCodes.shared.codes.values)).sorted()
                    if !known.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(known, id: \.self) { code in
                                    Button(code) { course = code }
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(CourseColors.color(for: code).opacity(course == code ? 0.35 : 0.15), in: Capsule())
                                        .foregroundStyle(CourseColors.color(for: code))
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .bentoScreen()
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            do {
                                try await onAdd(name, type, hasDeadline ? deadline : nil, type == "School" ? course : nil)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            saving = false
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
