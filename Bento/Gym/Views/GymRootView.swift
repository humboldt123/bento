import SwiftUI
import SwiftData

/// da gym: the old Lifta app, presented from the Bento menu
struct GymRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var gymSession = GymSession()

    var body: some View {
        TabView(selection: $gymSession.tab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            ActiveSessionView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle.fill")
                }
                .tag(1)

            BodyMapView()
                .tabItem {
                    Label("Body", systemImage: "figure.stand")
                }
                .tag(2)

            ProfileView()
                .tabItem {
                    Label("You", systemImage: "person.fill")
                }
                .tag(3)
        }
        .tint(.primary)
        .environment(gymSession)
        .task { resumeToday() }
    }

    /// Re-opens today's workout if the app was closed mid-session (it's only kept in memory)
    private func resumeToday() {
        guard gymSession.active == nil else { return }
        let start = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.date >= start },
                                                         sortBy: [SortDescriptor(\.date, order: .reverse)])
        let today = (try? modelContext.fetch(descriptor)) ?? []
        // Unfinished = still has planned sets (Finish removes them)
        if let open = today.first(where: { $0.entries.contains { $0.sets.contains(where: \.isPlanned) } }) {
            gymSession.active = open
        }
    }
}
