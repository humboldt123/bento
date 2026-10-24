import SwiftUI
import SwiftData
import AVKit

struct ExerciseDetailView: View {
    let exercise: ExerciseDefinition
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Gym.name) private var gyms: [Gym]
    @AppStorage(CurrentGym.storageKey) private var currentGymName = ""

    private var currentGym: Gym? {
        gyms.first { $0.name == currentGymName }
    }

    /// Machines and cables: chart one gym at a time
    @State private var chartGym: String?

    private var gymSpecific: Bool { WorkoutEngine.isGymSpecific(exercise) }

    /// Gyms where this exercise was done, most recent first
    private var gymsWithHistory: [String] {
        var seen: [String] = []
        for s in sessions where s.entries.contains(where: { $0.exerciseId == exercise.id }) {
            if let g = s.gymName, !seen.contains(g) { seen.append(g) }
        }
        return seen
    }

    private var shownGym: String? {
        guard gymSpecific else { return nil }
        if let chartGym, gymsWithHistory.contains(chartGym) { return chartGym }
        return gymsWithHistory.contains(currentGymName) ? currentGymName : gymsWithHistory.first
    }

    private var history: [(date: Date, estimated1RM: Double, topWeight: Double, topReps: Int)] {
        WorkoutEngine.exerciseHistory(exerciseId: exercise.id, sessions: Array(sessions), gymName: shownGym)
    }

    private var pr: (weight: Double, reps: Int, e1rm: Double, date: Date)? {
        guard let best = history.max(by: { $0.estimated1RM < $1.estimated1RM }) else { return nil }
        return (best.topWeight, best.topReps, best.estimated1RM, best.date)
    }

    private var pastEntries: [(date: Date, sets: [WorkoutSet])] {
        sessions.compactMap { session in
            guard let entry = session.entries.first(where: { $0.exerciseId == exercise.id }) else {
                return nil
            }
            return (session.date, entry.sortedSets)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                videoSection
                aliasSection
                gymSection
                muscleSection
                prSection
                chartSection
                historySection
            }
            .padding()
        }
        .bentoScreen()
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Video

    @ViewBuilder
    private var videoSection: some View {
        if let url = exercise.videoURL {
            LoopingVideo(url: url)
                .frame(height: 220)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .bentoCard(cornerRadius: 18)
        } else if let url = exercise.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.gray.opacity(0.2))
                    .frame(height: 200)
                    .overlay { ProgressView() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .bentoCard(cornerRadius: 18)
        }
    }

    // MARK: - Aliases

    @ViewBuilder
    private var aliasSection: some View {
        if exercise.exerciseType?.hasPrefix("db_1") == true {
            Label("One arm at a time: left first, right matches left's reps", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !exercise.aliases.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Also called")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(exercise.aliases.joined(separator: " · "))
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Gym

    @ViewBuilder
    private var gymSection: some View {
        if let gym = currentGym {
            let status = gym.status(of: exercise.id)
            HStack {
                GymBadge(name: gym.name)
                Text(gym.name)
                    .font(.subheadline.bold())
                Spacer()
                Picker("Available", selection: Binding(
                    get: { status },
                    set: { gym.setStatus($0, for: exercise.id) }
                )) {
                    Text("Here").tag(GymAvailability.confirmed)
                    Text("Not here").tag(GymAvailability.missing)
                    Text("Unsure").tag(GymAvailability.unknown)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            .padding()
            .bentoCard(cornerRadius: 18)
        }
    }

    // MARK: - Muscles

    private var muscleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Muscles")
                .font(.headline)

            if !exercise.targetMuscles.isEmpty {
                HStack(spacing: 4) {
                    Text("Target:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(exercise.targetMuscles.map(\.name).joined(separator: ", "))
                        .font(.caption)
                }
            }

            if !exercise.synergistMuscles.isEmpty {
                HStack(spacing: 4) {
                    Text("Synergist:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(exercise.synergistMuscles.map(\.name).joined(separator: ", "))
                        .font(.caption)
                }
            }

            if !exercise.equipment.isEmpty {
                HStack(spacing: 4) {
                    Text("Equipment:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(exercise.equipment.map(\.name).joined(separator: ", "))
                        .font(.caption)
                }
            }

            if !exercise.bodyParts.isEmpty {
                HStack(spacing: 4) {
                    Text("Body Part:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(exercise.bodyParts.map(\.name).joined(separator: ", "))
                        .font(.caption)
                }
            }
        }
        .padding()
        .bentoCard(cornerRadius: 18)
    }

    // MARK: - PR

    @ViewBuilder
    private var prSection: some View {
        if let pr {
            HStack {
                VStack(alignment: .leading) {
                    Text("Personal Record")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("\(pr.weight.clean) lb × \(pr.reps)")
                        .font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Est. 1RM")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("\(pr.e1rm.clean) lb")
                        .font(.title3.bold())
                    Text(pr.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .bentoCard(cornerRadius: 18)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        if history.count >= 2 || (gymSpecific && gymsWithHistory.count > 1) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Estimated 1RM Over Time")
                        .font(.headline)
                    Spacer()
                    if gymSpecific, gymsWithHistory.count > 1 {
                        Menu {
                            ForEach(gymsWithHistory, id: \.self) { g in Button(g) { chartGym = g } }
                        } label: {
                            Label(shownGym ?? "", systemImage: "chevron.down").font(.caption.bold())
                        }
                    } else if let shownGym {
                        Text(shownGym).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if history.count >= 2 {
                    SimpleChart(data: history.map { ($0.date, $0.estimated1RM) })
                        .frame(height: 160)
                } else {
                    Text("Not enough sessions here yet to chart")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .bentoCard(cornerRadius: 18)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)

            if pastEntries.isEmpty {
                Text("No history for this exercise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pastEntries.prefix(20), id: \.date) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(entry.sets.map(\.displayText).joined(separator: "  |  "))
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding(16)
        .bentoCard(cornerRadius: 18)
    }
}

// MARK: - Simple Chart (no Charts framework dependency)

struct SimpleChart: View {
    let data: [(date: Date, value: Double)]

    var body: some View {
        GeometryReader { geo in
            let minVal = (data.map(\.value).min() ?? 0) * 0.9
            let maxVal = (data.map(\.value).max() ?? 1) * 1.1
            let range = max(maxVal - minVal, 1)

            let points: [CGPoint] = data.enumerated().map { i, d in
                let x = data.count > 1 ? CGFloat(i) / CGFloat(data.count - 1) * geo.size.width : geo.size.width / 2
                let y = geo.size.height - ((d.value - minVal) / range) * geo.size.height
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Grid lines
                ForEach(0..<4) { i in
                    let y = geo.size.height * CGFloat(i) / 3
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

                // Line
                if points.count >= 2 {
                    Path { p in
                        p.move(to: points[0])
                        for point in points.dropFirst() {
                            p.addLine(to: point)
                        }
                    }
                    .stroke(Color.primary, lineWidth: 2)
                }

                // Points
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(points[i])
                }

                // Y-axis labels
                VStack {
                    Text(maxVal.clean)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(minVal.clean)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Looping Video

/// Muted, autoplaying loop like the Lyfta exercise demos. Our own tiny player instead of AVPlayer:
/// AVAssetReader pulls the video track out of the mp4 and an AVSampleBufferDisplayLayer shows it.
/// Neither touches the audio session, so Spotify etc keeps playing, and there are no controls or
/// AirPlay button because there's no player to control.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    final class LoopView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var feeder: LoopFeeder?
    }

    func makeUIView(context: Context) -> LoopView {
        let view = LoopView()
        let display = view.layer as! AVSampleBufferDisplayLayer
        display.videoGravity = .resizeAspect
        view.feeder = LoopFeeder(url: url, display: display)
        return view
    }

    func updateUIView(_ view: LoopView, context: Context) {}

    static func dismantleUIView(_ view: LoopView, coordinator: ()) {
        view.feeder?.stop()
        view.feeder = nil
    }
}

/// Feeds a display layer the same clip over and over, shifting each pass's timestamps by the clip
/// length so the layer sees one endless video. Everything after init runs on `queue`.
final class LoopFeeder: @unchecked Sendable {
    private let display: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "LoopFeeder")
    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var offset = CMTime.zero
    private var duration = CMTime.zero
    private var stopped = false

    init(url: URL, display: AVSampleBufferDisplayLayer) {
        self.display = display
        Task {
            guard let file = await Self.localFile(for: url) else { return }
            let asset = AVURLAsset(url: file)
            guard let loaded = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration) else { return }
            // Only ever used on `queue` from here on
            nonisolated(unsafe) let track = loaded
            self.queue.async { self.start(asset: asset, track: track, duration: duration) }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.display.stopRequestingMediaData()
            self.reader?.cancelReading()
        }
    }

    private func start(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime) {
        guard !stopped else { return }
        self.asset = asset
        self.track = track
        self.duration = duration
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        guard let timebase, openReader() else { return }
        display.controlTimebase = timebase
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
        display.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feed() }
    }

    /// Fresh reader from the start of the clip; compressed samples, the layer decodes them
    private func openReader() -> Bool {
        guard let asset, let track, let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return false }
        self.reader = reader
        self.output = output
        return true
    }

    private func feed() {
        while !stopped && display.isReadyForMoreMediaData {
            if let sample = output?.copyNextSampleBuffer() {
                if let shifted = Self.shift(sample, by: offset) { display.enqueue(shifted) }
            } else {
                // End of the clip: go again, later on the timeline
                offset = offset + duration
                guard openReader() else { display.stopRequestingMediaData(); return }
            }
        }
    }

    private static func shift(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out
    }

    /// AVAssetReader only reads files, so remote demos get downloaded to Caches once
    private static func localFile(for url: URL) async -> URL? {
        if url.isFileURL { return url }
        let dir = URL.cachesDirectory.appending(path: "ExerciseVideos")
        let file = dir.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: tmp, to: file)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
