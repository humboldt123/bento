import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video -> looping GIF (ImageIO). Shared with the share extension, which converts X "GIFs"
/// (served as silent MP4s) back into real GIFs.
enum GifMaker {
    /// Whether X GIFs are converted after download (app group defaults, so the share extension sees it too)
    static var convertXGifs: Bool {
        get { BentoStorage.groupDefaults.object(forKey: "convertXGifs") as? Bool ?? true }
        set { BentoStorage.groupDefaults.set(newValue, forKey: "convertXGifs") }
    }

    /// Replaces a downloaded MP4 with a GIF of the whole clip (15 fps, at most 480 px wide)
    static func convertDownload(_ mp4: URL) async throws -> URL {
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        let width = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize).width ?? 480
        let gif = mp4.deletingPathExtension().appendingPathExtension("gif")
        try? FileManager.default.removeItem(at: gif)
        try await make(from: asset, range: 0...max(duration, 0.1), fps: 15, width: min(480, Int(width)), to: gif) { _ in }
        try? FileManager.default.removeItem(at: mp4)
        return gif
    }

    static func make(from asset: AVAsset, range: ClosedRange<Double>, fps: Int, width: Int, to url: URL,
                    progress: @escaping @MainActor (Double) -> Void) async throws {
        let step = 1.0 / Double(fps)
        let times = stride(from: range.lowerBound, to: range.upperBound, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var done = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(dest, image, frameProps) }
            done += 1
            let fraction = Double(done) / Double(times.count)
            await progress(fraction)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
