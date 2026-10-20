import SwiftUI
import SwiftData

@main
struct BentoApp: App {
    let exerciseStore = ExerciseStore()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            WorkoutSession.self,
            WorkoutEntry.self,
            WorkoutSet.self,
            Gym.self,
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            HomeMenuView()
                .environment(exerciseStore)
                .fontDesign(.rounded)
                .tint(.primary)
        }
        .modelContainer(sharedModelContainer)
    }
}
