import SwiftUI

/// Shared between Da Gym's tabs so Home can start a workout that shows up in Log
@MainActor
@Observable
final class GymSession {
    var active: WorkoutSession?
    var tab = 0
}
