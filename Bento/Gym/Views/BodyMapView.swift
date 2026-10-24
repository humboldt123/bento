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

    /// Hard sets per muscle, not pounds. Pounds aren't comparable across exercises: when sets go near
    /// failure, growth is about the same from ~30% 1RM up (Schoenfeld et al., 2017, J Strength Cond Res
    /// 31(12); Lopez et al., 2021, Med Sci Sports Exerc 53(6)), so a 200 lb leg press set and a 30 lb
    /// dumbbell set are each one set. Per-muscle dose is counted in sets near failure (Baz-Valle et al.,
    /// 2022, J Hum Kinet 81). Each set counts 1 for target muscles and ½ for helpers, the weighting that
    /// fit 67 studies best (Pelland et al., Sports Med, doi 10.1007/s40279-025-02344-w).
    /// Warm-ups don't count. Sets past 30 reps count ½: very light loads (~20% 1RM) grew muscle less
    /// (Lasevicius et al., 2018, Eur J Sport Sci 18(6)); the 30-rep cutoff is our own heuristic.
    private var muscleActivity: [Int: Double] {
        var activity: [Int: Double] = [:]
        for session in filteredSessions {
            for entry in session.entries {
                guard let ex = store.exercise(id: entry.exerciseId) else { continue }
                let sets = entry.sets
                    .filter { !$0.isPlanned && ($0.reps ?? 0) > 0 && !$0.tags.contains(SetTag.warmup.rawValue) }
                    .reduce(0.0) { $0 + (($1.reps ?? 0) > 30 ? 0.5 : 1) }
                for mid in ex.targetMuscleIds {
                    activity[mid, default: 0] += sets
                }
                for mid in ex.synergistMuscleIds {
                    activity[mid, default: 0] += sets * 0.5
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

// MARK: - Session figure

/// Front and back figures for one workout: muscles you've worked go red by how many sets they've
/// had (targets count 1, helpers ½), muscles today's plan still hits pulse red
struct SessionMuscleFigure: View {
    /// Muscle id → effective sets done today
    let done: [Int: Double]
    /// Muscles the rest of today's plan hits
    let planned: Set<Int>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            side(front: true)
            side(front: false)
        }
        .frame(height: 170)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func side(front: Bool) -> some View {
        ZStack {
            if let base = MuscleImageLoader.loadOverlay(named: front ? "front_grey_body" : "back_grey_body") {
                Image(uiImage: base).resizable().aspectRatio(contentMode: .fit)
            }
            ForEach(MuscleInfo.allMuscles) { muscle in
                let sets = done[muscle.id] ?? 0
                let isPlanned = planned.contains(muscle.id)
                if sets > 0 || isPlanned {
                    ForEach(front ? muscle.frontImages : muscle.backImages, id: \.self) { name in
                        if let img = MuscleImageLoader.loadOverlay(named: name) {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(opacity(sets: sets, planned: isPlanned))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The overlays are already red, so sets done just set how solid they are: ~3 sets is a light
    /// day for a muscle, 6+ a full one. Still-planned muscles fade in and out on top of that.
    private func opacity(sets: Double, planned: Bool) -> Double {
        let solid = sets >= 6 ? 0.95 : sets >= 3 ? 0.75 : sets > 0 ? 0.5 : 0
        guard planned else { return solid }
        if reduceMotion { return max(solid, 0.4) }
        return pulse ? max(solid, 0.6) : max(solid * 0.6, 0.1)
    }
}
