import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

/// Simple video editor: stitch clips, trim each, crop to an aspect, add music. Built as one
/// AVComposition, so the preview and the export are the same thing.
struct EditView: View {
    struct Clip: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let duration: Double
        var range: ClosedRange<Double>
    }

    enum Crop: String, CaseIterable, Identifiable {
        case original = "Original", tall = "9:16", square = "1:1", portrait = "4:5", wide = "16:9"
        var id: String { rawValue }
        /// width / height
        var aspect: Double? {
            switch self {
            case .original: nil
            case .tall: 9.0 / 16
            case .square: 1
            case .portrait: 4.0 / 5
            case .wide: 16.0 / 9
            }
        }
    }

    @State private var clips: [Clip] = []
    @State private var selected: UUID?
    @State private var crop: Crop = .original
    @State private var music: URL?
    @State private var musicVolume = 0.8
    @State private var keepOriginalSound = true

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingClips = false
    @State private var importingMusic = false
    @State private var loading = false
    @State private var previewing = false
    @State private var working = false
    @State private var progress = 0.0
    @State private var result: URL?
    @State private var error: String?

    private var selectedIndex: Int? { clips.firstIndex { $0.id == selected } }
    private var total: Double { clips.reduce(0) { $0 + ($1.range.upperBound - $1.range.lowerBound) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result { ResultCard(url: result) }
                    clipStrip
                    if loading { ProgressView("Loading…") }
                    if let i = selectedIndex {
                        PreviewPlayer(url: clips[i].url, seek: clips[i].range.lowerBound)
                        RangeBar(range: $clips[i].range, duration: clips[i].duration)
                            .id(clips[i].id)
                    } else if clips.isEmpty, !loading {
                        Text("Add one or more videos. They play in order.")
                            .foregroundStyle(.secondary)
                    }
                    if !clips.isEmpty {
                        cropPicker
                        musicSection
                        HStack(spacing: 10) {
                            Button {
                                previewing = true
                            } label: {
                                Label("Preview", systemImage: "play.fill")
                            }
                            .buttonStyle(BentoButtonStyle())
                            Button {
                                Task { await export() }
                            } label: {
                                Label(working ? "Saving… \(Int(progress * 100))%" : "Export \(clock(total))", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(BentoButtonStyle())
                            .disabled(working)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                }
                .padding(20)
            }
            .bentoScreen()
            .navigationTitle("edit")
            .bentoCloseButton()
            .fileImporter(isPresented: $importingClips, allowedContentTypes: [.movie], allowsMultipleSelection: true) { picked in
                guard case .success(let urls) = picked else { return }
                Task { await add(urls.compactMap { try? VideoIO.copyIn($0, scoped: true) }) }
            }
            .fileImporter(isPresented: $importingMusic, allowedContentTypes: [.audio, .movie]) { picked in
                if case .success(let url) = picked { music = try? VideoIO.copyIn(url, scoped: true) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    loading = true
                    var urls: [URL] = []
                    for item in items {
                        if let movie = try? await item.loadTransferable(type: PickedMovie.self) { urls.append(movie.url) }
                    }
                    photoItems = []
                    await add(urls)
                }
            }
            .sheet(isPresented: $previewing) {
                CompositionPreview(build: { try await build() })
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: Pieces

    private var clipStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                        ClipThumb(clip: clip, index: i + 1, isSelected: clip.id == selected)
                            .onTapGesture { selected = clip.id }
                            .contextMenu {
                                if i > 0 { Button("Move left", systemImage: "arrow.left") { clips.swapAt(i, i - 1) } }
                                if i < clips.count - 1 { Button("Move right", systemImage: "arrow.right") { clips.swapAt(i, i + 1) } }
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(clip) }
                            }
                    }
                    PhotosPicker(selection: $photoItems, matching: .videos) {
                        AddTile(symbol: "plus", label: "Media")
                    }
                    Button { importingClips = true } label: { AddTile(symbol: "folder", label: "Files") }
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
            if clips.count > 1 {
                Text("Hold a clip to reorder or remove it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cropPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crop").font(.headline)
            Picker("Crop", selection: $crop) {
                ForEach(Crop.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Music").font(.headline)
                Spacer()
                if music != nil {
                    Button("Remove", role: .destructive) { music = nil }.font(.caption)
                }
            }
            Button {
                importingMusic = true
            } label: {
                Label(music?.deletingPathExtension().lastPathComponent ?? "Add a song from Files", systemImage: "music.note")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .bentoCard(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            if music != nil {
                HStack {
                    Image(systemName: "speaker.wave.1")
                    Slider(value: $musicVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3")
                }
                .tint(.primary)
            }
            Toggle("Keep the clips' own sound", isOn: $keepOriginalSound)
                .tint(.primary)
                .font(.subheadline)
        }
    }

    // MARK: Clips

    private func add(_ urls: [URL]) async {
        loading = true
        defer { loading = false }
        for url in urls {
            guard let d = try? await AVURLAsset(url: url).load(.duration).seconds, d > 0 else { continue }
            clips.append(Clip(url: url, duration: d, range: 0...d))
        }
        if selected == nil { selected = clips.first?.id }
        result = nil
    }

    private func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        if selected == clip.id { selected = clips.first?.id }
    }

    // MARK: Composition

    struct Built {
        let composition: AVComposition
        let video: AVVideoComposition
        let audio: AVAudioMix?
    }

    /// Every clip (trimmed) in order on one track, each center-cropped to fill the render size; music on its own track
    private func build() async throws -> Built {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        let aTrack = keepOriginalSound ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        // Render size: the first clip's upright size, cut to the chosen aspect, at most 1920 on the long side
        var render = CGSize(width: 1080, height: 1920)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for (i, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.url)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let natural = try await src.load(.naturalSize)
            let transform = try await src.load(.preferredTransform)
            let upright = natural.applying(transform)
            let size = CGSize(width: abs(upright.width), height: abs(upright.height))

            if i == 0 {
                var r = size
                if let a = crop.aspect {
                    r = size.width / size.height > a ? CGSize(width: size.height * a, height: size.height)
                                                     : CGSize(width: size.width, height: size.width / a)
                }
                let scale = min(1, 1920 / max(r.width, r.height))
                render = CGSize(width: (r.width * scale / 2).rounded() * 2, height: (r.height * scale / 2).rounded() * 2)
            }

            let range = CMTimeRange(start: CMTime(seconds: clip.range.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.range.upperBound, preferredTimescale: 600))
            try vTrack.insertTimeRange(range, of: src, at: cursor)
            if let aTrack, let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: srcAudio, at: cursor)
            }

            // Fill the frame (center crop): rotate upright, scale, then center
            let fill = max(render.width / size.width, render.height / size.height)
            let dx = (render.width - size.width * fill) / 2, dy = (render.height - size.height * fill) / 2
            let t = transform
                .concatenating(CGAffineTransform(scaleX: fill, y: fill))
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            layer.setTransform(t, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = cursor + range.duration
        }

        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = instructions

        var params: [AVMutableAudioMixInputParameters] = []
        if let aTrack {
            let p = AVMutableAudioMixInputParameters(track: aTrack)
            p.setVolume(music == nil ? 1 : 0.6, at: .zero)
            params.append(p)
        }
        if let music, let song = try await AVURLAsset(url: music).loadTracks(withMediaType: .audio).first,
           let mTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // Loop the song until the video ends
            let songLength = try await song.load(.timeRange).duration
            var at = CMTime.zero
            while at < cursor, songLength.seconds > 0 {
                let piece = CMTimeMinimum(songLength, cursor - at)
                try mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: song, at: at)
                at = at + piece
            }
            let p = AVMutableAudioMixInputParameters(track: mTrack)
            p.setVolume(Float(musicVolume), at: .zero)
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return Built(composition: comp, video: video, audio: params.isEmpty ? nil : mix)
    }

    private func export() async {
        working = true; error = nil; progress = 0
        defer { working = false }
        do {
            let built = try await build()
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw CocoaError(.featureUnsupported)
            }
            let out = VideoIO.output(named: clips.count == 1 ? clips[0].url : nil, suffix: "edit", ext: "mp4")
            session.outputURL = out
            session.outputFileType = .mp4
            session.videoComposition = built.video
            session.audioMix = built.audio
            session.shouldOptimizeForNetworkUse = true
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    progress = Double(session.progress)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { done.resume() }
            }
            ticker.cancel()
            if let e = session.error { throw e }
            result = out
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "+ Media" / "Files" buttons at the end of the clip strip
private struct AddTile: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
            Text(label).font(.caption2.bold())
        }
        .frame(width: 64, height: 86)
        .bentoCard(cornerRadius: 12)
    }
}

/// A thumbnail for one clip in the strip
private struct ClipThumb: View {
    let clip: EditView.Clip
    let index: Int
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
            }
            .frame(width: 64, height: 86)
            .clipped()
            Text("\(index) · \(clock(clip.range.upperBound - clip.range.lowerBound))")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary, lineWidth: isSelected ? 3 : 1.2))
        .task(id: clip.url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            if let cg = try? await generator.image(at: .zero).image { image = UIImage(cgImage: cg) }
        }
    }
}

/// Plays the whole edit, exactly as it will export
private struct CompositionPreview: View {
    let build: () async throws -> EditView.Built
    @State private var player: AVPlayer?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player).onAppear { player.play() }
                } else if let error {
                    Text(error).foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                let built = try await build()
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.video
                item.audioMix = built.audio
                player = AVPlayer(playerItem: item)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }
}
