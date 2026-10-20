import SwiftUI
import SwiftData

/// A tool on the Bento home screen
enum BentoTool: String, CaseIterable, Identifiable {
    case gym, todo, flashcards, downloader, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gym: "da gym"
        case .todo: "tasks"
        case .flashcards: "flashcards"
        case .downloader: "downloader"
        case .files: "files"
        }
    }

    var symbol: String {
        switch self {
        case .gym: "dumbbell.fill"
        case .todo: "checklist"
        case .flashcards: "rectangle.on.rectangle.angled"
        case .downloader: "arrow.down.circle.fill"
        case .files: "folder.fill"
        }
    }

    var isReady: Bool {
        switch self {
        case .gym, .todo, .flashcards, .downloader, .files: true
        }
    }
}

struct HomeMenuView: View {
    @Environment(ExerciseStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @State private var openTool: BentoTool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                    .padding(.bottom, 6)

                Button { openTool = .gym } label: { GymCard() }
                    .buttonStyle(BentoPressStyle())

                HStack(alignment: .top, spacing: 14) {
                    Button { openTool = .todo } label: { TasksCard() }
                        .buttonStyle(BentoPressStyle())

                    VStack(spacing: 14) {
                        Button { openTool = .flashcards } label: { FlashcardsCard() }
                            .buttonStyle(BentoPressStyle())
                        Button { openTool = .downloader } label: { SmallToolCard(tool: .downloader, subtitle: "paste or share") }
                            .buttonStyle(BentoPressStyle())
                    }
                }

                Button { openTool = .files } label: { FilesCard() }
                    .buttonStyle(BentoPressStyle())
            }
            .padding(20)
        }
        .background(Color.bentoPaper.ignoresSafeArea())
        .task {
            await DeckStore.shared.refreshIfStale()
            await GymSync.run(store: store, context: modelContext)
        }
        .fontDesign(.rounded)
        .onChange(of: openTool) { old, new in
            // Back from the gym: send any new workouts to Notion
            if old == .gym, new == nil { Task { await GymSync.run(store: store, context: modelContext) } }
        }
        .fullScreenCover(item: $openTool) { tool in
            Group {
                switch tool {
                case .gym: GymRootView()
                case .todo: TodoView()
                case .flashcards: FlashcardsView()
                case .downloader: DownloaderView()
                case .files: FilesView()
                }
            }
            .fontDesign(.rounded)
            .tint(.primary)
            .environment(\.closeTool) { openTool = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.split.2x2")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 56, height: 56)
                .bentoCard(cornerRadius: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("bento")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).lowercased())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }
}

// MARK: - Cards

/// Wide card: what's next at the gym plus the last 12 weeks
private struct GymCard: View {
    @Query(sort: \WorkoutSession.date, order: .reverse) private var allSessions: [WorkoutSession]
    private var sessions: [WorkoutSession] { allSessions.filter(\.isLogged) }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                BentoIcon(symbol: BentoTool.gym.symbol)
                Spacer(minLength: 8)
                Text("da gym")
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MiniHeatmap(sessions: sessions)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .bentoCard()
    }

    private var subtitle: String {
        guard let last = sessions.first else { return "no workouts yet" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last.date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
        let when = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return "last lift \(when) · \(sessions.count) total"
    }
}

private struct MiniHeatmap: View {
    let sessions: [WorkoutSession]
    private let weeks = 12

    var body: some View {
        let days = WorkoutEngine.heatmapData(sessions: sessions, weeks: weeks)
        let leading = days.first.map { Calendar.current.component(.weekday, from: $0.date) - 1 } ?? 0
        let trimmed = Array(days.dropFirst((7 - leading) % 7))
        let columns = stride(from: 0, to: trimmed.count, by: 7).map { Array(trimmed[$0..<min($0 + 7, trimmed.count)]) }

        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(week) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.sets > 0 ? Color.bentoActivity.opacity(0.35 + 0.16 * Double(day.intensity)) : Color.primary.opacity(0.06))
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
    }
}

/// Tall card: the next few things due in Notion
private struct TasksCard: View {
    @State private var items: [TodoItem] = []
    @State private var status = "loading…"
    private let codes = CourseCodes.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BentoIcon(symbol: BentoTool.todo.symbol)
            Text(BentoTool.todo.title)
                .font(.title3.bold())
            if items.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(4)) { item in
                    let course = codes.label(for: item)
                    HStack(alignment: .top, spacing: 7) {
                        Capsule()
                            .fill(course.map(CourseColors.color(for:)) ?? Color.primary.opacity(0.18))
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                if let course {
                                    Text(course)
                                        .foregroundStyle(CourseColors.color(for: course))
                                        .fontWeight(.semibold)
                                }
                                if let due = item.deadline {
                                    Text(dueLabel(due))
                                        .foregroundStyle(due < .now ? .red : .secondary)
                                }
                            }
                            .font(.caption2)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 2 * 140 + 14, alignment: .topLeading)
        .bentoCard()
        .task { await load() }
    }

    private func dueLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if date < .now && !cal.isDateInToday(date) { return "overdue" }
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated)).lowercased()
    }

    private func load() async {
        guard let client = NotionTodoClient() else {
            status = "connect notion in Config.xcconfig"
            return
        }
        do {
            items = RecentlyClosed.filter(try await client.openItems())
            status = items.isEmpty ? "all clear ✨" : ""
            await codes.resolve(items, client: client)
        } catch {
            status = "couldn't reach notion"
        }
    }
}

private struct FlashcardsCard: View {
    private let progress = StudyProgress.shared

    var body: some View {
        let due = DeckStore.shared.decks.reduce(0) { $0 + progress.due(in: $1).count }
        VStack(alignment: .leading, spacing: 6) {
            BentoIcon(symbol: BentoTool.flashcards.symbol)
            Spacer(minLength: 0)
            Text(BentoTool.flashcards.title)
                .font(.headline)
            Text(due == 0 ? "all caught up" : "\(due) due")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .bentoCard()
    }
}

private struct SmallToolCard: View {
    let tool: BentoTool
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BentoIcon(symbol: tool.symbol)
            Spacer(minLength: 0)
            Text(tool.title)
                .font(.headline)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .bentoCard()
    }
}

/// Wide card: newest downloads as thumbnails
private struct FilesCard: View {
    @State private var recent: [FileItem] = []

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                BentoIcon(symbol: BentoTool.files.symbol)
                Spacer(minLength: 0)
                Text(BentoTool.files.title)
                    .font(.headline)
                Text(recent.isEmpty ? "downloads land here" : "\(recent.count) downloads")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: -18) {
                ForEach(recent.prefix(3)) { item in
                    Thumbnail(item: item)
                        .frame(width: 54, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary, lineWidth: 1.2))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .bentoCard()
        .task {
            BentoStorage.collectInbox()
            recent = await FileItem.list(BentoStorage.downloads)
                .filter { !$0.isFolder }
                .sorted { $0.modified > $1.modified }
        }
    }
}

private struct SoonCard: View {
    let tool: BentoTool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BentoIcon(symbol: tool.symbol)
            Spacer(minLength: 0)
            Text(tool.title)
                .font(.headline)
            Text("soon")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .opacity(0.45)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .bentoCard()
    }
}

private struct BentoIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 36, height: 36)
            .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
    }
}

// MARK: - Back to the menu

extension EnvironmentValues {
    /// Closes the open tool and returns to the Bento menu
    @Entry var closeTool: () -> Void = {}
}

struct BentoCloseButton: ViewModifier {
    @Environment(\.closeTool) private var closeTool

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closeTool()
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("Bento menu")
            }
        }
    }
}

extension View {
    /// Adds the grid button that goes back to the Bento menu
    func bentoCloseButton() -> some View {
        modifier(BentoCloseButton())
    }
}
