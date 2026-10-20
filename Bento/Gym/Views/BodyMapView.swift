import SwiftUI
import SwiftData

struct BodyMapView: View {
    @Environment(ExerciseStore.self) private var store
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var timeFilter: TimeFilter = .week

    enum TimeFilter: String, CaseIterable {
        case today = "Today"
        case week = "This Week"
        case all = "All Time"
    }

    private var filteredSessions: [WorkoutSession] {
        let calendar = Calendar.current
        switch timeFilter {
        case .today:
            return sessions.filter { calendar.isDateInToday($0.date) }
        case .week:
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
            return sessions.filter { $0.date >= weekAgo }
        case .all:
            return Array(sessions)
        }
    }

    private var muscleRecovery: [WorkoutEngine.MuscleRecovery] {
        WorkoutEngine.muscleRecovery(sessions: Array(sessions), exerciseStore: store)
    }

    /// Compute which muscles have been worked and their intensity
    private var muscleActivity: [Int: Double] {
        var activity: [Int: Double] = [:]
        for session in filteredSessions {
            for entry in session.entries {
                guard let ex = store.exercise(id: entry.exerciseId) else { continue }
                let volume = entry.sets.reduce(0.0) { $0 + $1.volume }
                for mid in ex.targetMuscleIds {
                    activity[mid, default: 0] += volume
                }
                for mid in ex.synergistMuscleIds {
                    activity[mid, default: 0] += volume * 0.5
                }
            }
        }
        return activity
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Time filter
                    Picker("Filter", selection: $timeFilter) {
                        ForEach(TimeFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // Body maps + legend
                    VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        bodyOverlay(side: .front)
                        bodyOverlay(side: .back)
                    }

                    HStack(spacing: 4) {
                        Circle().fill(Color.primary.opacity(0.08)).frame(width: 10, height: 10)
                        Text("Not hit").font(.system(size: 9))
                        Spacer()
                        Circle().fill(Color.bentoActivity.opacity(0.4)).frame(width: 10, height: 10)
                        Text("Light").font(.system(size: 9))
                        Spacer()
                        Circle().fill(Color.bentoActivity.opacity(0.7)).frame(width: 10, height: 10)
                        Text("Moderate").font(.system(size: 9))
                        Spacer()
                        Circle().fill(Color.bentoActivity).frame(width: 10, height: 10)
                        Text("Heavy").font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    }
                    .padding(16)
                    .bentoCard()
                    .padding(.horizontal)

                    // Muscle list
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Muscle Recovery")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 14)

                        ForEach(muscleRecovery.sorted(by: { $0.recoveryPercent < $1.recoveryPercent })) { recovery in
                            MuscleRecoveryRow(recovery: recovery)
                        }
                    }
                    .padding(.bottom, 10)
                    .bentoCard()
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .bentoScreen()
            .navigationTitle("Body")
            .bentoCloseButton()
        }
    }

    // MARK: - Body Overlay

    enum BodySide { case front, back }

    @ViewBuilder
    private func bodyOverlay(side: BodySide) -> some View {
        let baseName = side == .front ? "front_grey_body" : "back_grey_body"
        let maxVolume = muscleActivity.values.max() ?? 1

        ZStack {
            // Base body silhouette
            if let base = MuscleImageLoader.loadOverlay(named: baseName) {
                Image(uiImage: base)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // Muscle overlays
            ForEach(MuscleInfo.allMuscles) { muscle in
                let images = side == .front ? muscle.frontImages : muscle.backImages
                let volume = muscleActivity[muscle.id] ?? 0

                if volume > 0 {
                    ForEach(images, id: \.self) { imageName in
                        if let img = MuscleImageLoader.loadOverlay(named: imageName) {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .colorMultiply(muscleColor(volume: volume, max: maxVolume))
                                .opacity(0.8)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func muscleColor(volume: Double, max: Double) -> Color {
        let ratio = volume / max
        if ratio > 0.7 { return .bentoActivity }
        if ratio > 0.3 { return Color.bentoActivity.opacity(0.7) }
        return Color.bentoActivity.opacity(0.4)
    }
}

// MARK: - Muscle Recovery Row

struct MuscleRecoveryRow: View {
    let recovery: WorkoutEngine.MuscleRecovery

    var body: some View {
        HStack {
            Text(recovery.muscle.name)
                .font(.subheadline)

            Spacer()

            // Recovery bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(recoveryColor)
                        .frame(width: geo.size.width * recovery.recoveryPercent)
                }
            }
            .frame(width: 80, height: 6)

            if recovery.isRecovered {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Text("\(Int(recovery.recoveryPercent * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var recoveryColor: Color {
        if recovery.recoveryPercent >= 1.0 { return .green }
        if recovery.recoveryPercent >= 0.7 { return .yellow }
        return .orange
    }
}
