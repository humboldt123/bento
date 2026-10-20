import SwiftUI
import AVKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// Quick video tools: compress and video -> GIF (the editor is in EditView.swift). Everything runs on device (AVFoundation);
// results land in Bento's Downloads folder and can be saved to Photos or shared.

// MARK: - Compress

struct CompressView: View {
    /// Shorter side and video bitrate; sizes are honest because the bitrate is ours
    private struct Option: Identifiable, Hashable {
        let label: String
        let shortSide: Int
        let bitrate: Int
        var id: String { label }
    }

    private static let ladder = [
        Option(label: "1080p · high", shortSide: 1080, bitrate: 4_000_000),
        Option(label: "720p · good", shortSide: 720, bitrate: 2_000_000),
        Option(label: "720p · small", shortSide: 720, bitrate: 1_000_000),
        Option(label: "540p · tiny", shortSide: 540, bitrate: 600_000),
        Option(label: "480p · tinier", shortSide: 480, bitrate: 350_000),
    ]

    @State private var source: URL?
    @State private var duration: Double = 0
    @State private var choice: Option?
    @State private var result: URL?
    @State private var working = false
    @State private var progress = 0.0
    @State private var error: String?

    private var original: Int64 { source.flatMap(VideoIO.size) ?? 0 }

    /// Only options that actually shrink the file
    private var options: [Option] {
        Self.ladder.filter { estimate($0) < Int64(Double(original) * 0.9) }
    }

    private func estimate(_ o: Option) -> Int64 { Int64(Double(o.bitrate + 128_000) * duration / 8) }

    var body: some View {
        VideoToolScreen(title: "compress", source: $source, result: result, working: working, error: error) { asset, d in
            Text("Original: \(ByteCountFormatter.string(fromByteCount: original, countStyle: .file))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .onAppear { duration = d }
                .onChange(of: d) { _, d in duration = d }
            if options.isEmpty {
                Text("This video is already small; re-encoding wouldn't save space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        choice = option
                    } label: {
                        HStack {
                            Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                            Text(option.label).font(.headline)
                            Spacer()
                            Text("≈ " + ByteCountFormatter.string(fromByteCount: estimate(option), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .bentoCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !options.isEmpty {
                Button {
                    Task { await run(asset) }
                } label: {
                    if working {
                        Label("Compressing… \(Int(progress * 100))%", systemImage: "hourglass")
                    } else {
                        Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                .buttonStyle(BentoButtonStyle())
                .disabled(working || choice == nil)
            }
        }
        .onChange(of: source) { result = nil; choice = nil }
        .onChange(of: duration) { if choice == nil { choice = options.first { $0.shortSide == 720 } ?? options.first } }
    }

    private func run(_ asset: AVURLAsset) async {
        guard let choice else { return }
        working = true; error = nil; progress = 0
        defer { working = false }
        do {
            let out = VideoIO.output(named: source, suffix: "small", ext: "mp4")
            try await VideoTranscoder(asset: asset, output: out, shortSide: choice.shortSide, bitrate: choice.bitrate) { progress = $0 }.run()
            result = out
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - GIF

struct GifView: View {
    @State private var source: URL?
    @State private var range: ClosedRange<Double> = 0...1
    @State private var fps = 12
    @State private var width = 480
    @State private var result: URL?
    @State private var working = false
    @State private var progress = 0.0
    @State private var error: String?

    /// Long GIFs get huge fast
    private let maxLength = 15.0

    var body: some View {
        VideoToolScreen(title: "to gif", source: $source, result: result, working: working, error: error) { asset, duration in
            PreviewPlayer(url: source, seek: range.lowerBound)
            RangeBar(range: $range, duration: duration, maxLength: maxLength)
            Picker("Frame rate", selection: $fps) {
                ForEach([8, 12, 15, 20], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Width", selection: $width) {
                ForEach([320, 480, 640], id: \.self) { Text("\($0) px").tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                Task { await run(asset) }
            } label: {
                if working {
                    Label("Making GIF… \(Int(progress * 100))%", systemImage: "hourglass")
                } else {
                    Label("Make GIF", systemImage: "photo.stack")
                }
            }
            .buttonStyle(BentoButtonStyle())
            .disabled(working)
        }
        .onChange(of: source) { result = nil; range = 0...1 }
    }

    private func run(_ asset: AVURLAsset) async {
        working = true; error = nil; progress = 0
        defer { working = false }
        do {
            let out = VideoIO.output(named: source, suffix: nil, ext: "gif")
            try await GifMaker.make(from: asset, range: range, fps: fps, width: width, to: out) { progress = $0 }
            result = out
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Shared screen

/// Pick a video, then the tool's controls, then the result
private struct VideoToolScreen<Controls: View>: View {
    let title: String
    @Binding var source: URL?
    let result: URL?
    let working: Bool
    let error: String?
    @ViewBuilder let controls: (AVURLAsset, Double) -> Controls

    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var loading = false
    @State private var duration: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photoItem, matching: .videos) {
                            Label("Media", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(BentoButtonStyle())
                        Button {
                            importing = true
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                        .buttonStyle(BentoButtonStyle())
                    }
                    if loading { ProgressView("Loading video…") }
                    if let source, duration > 0 {
                        Text("\(source.lastPathComponent) · \(clock(duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let result { ResultCard(url: result) }
                        controls(AVURLAsset(url: source), duration)
                    } else if !loading {
                        Text("Pick a video to start.")
                            .foregroundStyle(.secondary)
                    }
                    if working && title == "compress" { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                }
                .padding(20)
            }
            .bentoScreen()
            .navigationTitle(title)
            .bentoCloseButton()
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie]) { picked in
                guard case .success(let url) = picked else { return }
                Task { await load { try VideoIO.copyIn(url, scoped: true) } }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    await load {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw CocoaError(.fileReadUnknown) }
                        return movie.url
                    }
                }
            }
        }
    }

    private func load(_ get: () async throws -> URL) async {
        loading = true
        defer { loading = false }
        do {
            let url = try await get()
            duration = try await AVURLAsset(url: url).load(.duration).seconds
            source = url
        } catch {
            source = nil
        }
    }
}

/// A finished file: preview, save to Photos, share (compact, shown right under the file name).
/// Saving to Photos moves it out of Bento's Downloads, so it lives in one place.
struct ResultCard: View {
    let url: URL
    @State private var current: URL?
    @State private var preview: URL?
    @State private var saved: String?

    private var file: URL { current ?? url }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bentoActivity)
                Text(file.lastPathComponent).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let size = VideoIO.size(file) {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(saved == "Saved ✓" ? "In your camera roll" : "In Files › Downloads")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Preview") { preview = file }
                Button(saved ?? "Save to Photos") {
                    Task {
                        do {
                            try await PhotoSaver.save(file)
                            // Keep a temp copy so Preview/Share still work, but drop it from Downloads
                            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(file.lastPathComponent)
                            try? FileManager.default.removeItem(at: tmp)
                            if (try? FileManager.default.moveItem(at: file, to: tmp)) != nil { current = tmp }
                            saved = "Saved ✓"
                        } catch { saved = "Couldn't save" }
                    }
                }
                .disabled(saved == "Saved ✓")
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bentoCard(cornerRadius: 16)
        .quickLookPreview($preview)
    }
}

/// Plays the picked video, jumping to the start of the selected range when it changes
struct PreviewPlayer: View {
    let url: URL?
    let seek: Double
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary, lineWidth: 1.5))
            .task(id: url) {
                if let url { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
            }
            .onChange(of: seek) { _, t in
                player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
    }
}

/// Two handles over a track; range is in seconds
struct RangeBar: View {
    @Binding var range: ClosedRange<Double>
    let duration: Double
    var maxLength: Double = .infinity

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width - 28
                let x0 = duration > 0 ? range.lowerBound / duration * w : 0
                let x1 = duration > 0 ? range.upperBound / duration * w : w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 8).padding(.horizontal, 14)
                    Rectangle().fill(Color.bentoActivity).frame(width: max(x1 - x0, 2), height: 8).offset(x: 14 + x0)
                    handle.offset(x: x0).gesture(DragGesture().onChanged { g in
                        let t = min(max(0, (g.location.x - 14) / w * duration), range.upperBound - 0.2)
                        range = t...min(range.upperBound, t + maxLength)
                    })
                    handle.offset(x: x1).gesture(DragGesture().onChanged { g in
                        let t = max(min(duration, (g.location.x - 14) / w * duration), range.lowerBound + 0.2)
                        range = max(range.lowerBound, t - maxLength)...t
                    })
                }
            }
            .frame(height: 30)
            HStack {
                Text(clock(range.lowerBound))
                Spacer()
                Text(clock(range.upperBound - range.lowerBound)).bold()
                Spacer()
                Text(clock(range.upperBound))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onAppear { if range == 0...1 { range = 0...min(duration, maxLength) } }
        .onChange(of: duration) { _, d in range = 0...min(d, maxLength) }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.systemBackground))
            .frame(width: 28, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary, lineWidth: 1.5))
            .overlay(Capsule().fill(Color.primary).frame(width: 3, height: 12))
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let s = max(0, seconds)
    return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - IO

/// A video from Photos, copied somewhere we can read it
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            Self(url: try VideoIO.copyIn(received.file, scoped: false))
        }
    }
}

enum VideoIO {
    static func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Copies into tmp so the file outlives the picker's sandbox grant
    static func copyIn(_ url: URL, scoped: Bool) throws -> URL {
        let ok = scoped && url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-in", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: url, to: dst)
        return dst
    }

    /// Downloads/<name>-<suffix>.<ext>, numbered if taken
    static func output(named source: URL?, suffix: String?, ext: String) -> URL {
        let base = (source?.deletingPathExtension().lastPathComponent ?? "video") + (suffix.map { "-" + $0 } ?? "")
        var url = BentoStorage.downloads.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = BentoStorage.downloads.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType, range: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw CocoaError(.featureUnsupported) }
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let range { session.timeRange = range }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        if let error = session.error { throw error }
        guard session.status == .completed else { throw CocoaError(.fileWriteUnknown) }
    }

    static func estimate(_ asset: AVAsset, preset: String) async -> Int64? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        session.outputFileType = .mp4
        return await withCheckedContinuation { done in
            session.estimateOutputFileLength { bytes, _ in done.resume(returning: bytes > 0 ? bytes : nil) }
        }
    }
}

/// Re-encodes to H.264 at a chosen bitrate and size (AVAssetReader -> AVAssetWriter), unlike the
/// export presets, which keep a fixed high quality and can make small videos bigger
final class VideoTranscoder: @unchecked Sendable {
    private let asset: AVAsset
    private let output: URL
    private let shortSide: Int
    private let bitrate: Int
    private let progress: @MainActor (Double) -> Void

    init(asset: AVAsset, output: URL, shortSide: Int, bitrate: Int, progress: @escaping @MainActor (Double) -> Void) {
        self.asset = asset; self.output = output; self.shortSide = shortSide; self.bitrate = bitrate; self.progress = progress
    }

    func run() async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds

        // Scale so the shorter side fits, never up; even dimensions for the encoder
        let scale = min(1, Double(shortSide) / Double(min(natural.width, natural.height)))
        func even(_ v: CGFloat) -> Int { max(2, Int((Double(v) * scale / 2).rounded()) * 2) }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: even(natural.width),
            AVVideoHeightKey: even(natural.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = [(videoOut, videoIn, true)]
        if let audio {
            let audioOut = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOut)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 128_000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
            pairs.append((audioOut, audioIn, false))
        }

        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Pump each track on its own queue; resume once every track has run out
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (out, input, isVideo) in pairs {
                group.enter()
                let state = Flag()
                let queue = DispatchQueue(label: "bento.transcode.\(isVideo ? "v" : "a")")
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData && !state.finished {
                        guard let buffer = out.copyNextSampleBuffer(), input.append(buffer) else {
                            state.finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        if isVideo, duration > 0 {
                            let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration
                            Task { @MainActor in self.progress(min(1, t)) }
                        }
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// Set once a track has run out (or failed); read on the writer's queue
private final class Flag: @unchecked Sendable { var finished = false }
