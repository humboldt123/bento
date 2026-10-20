import SwiftUI

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
    }
}
