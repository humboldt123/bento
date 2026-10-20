import Foundation
import Photos
import UniformTypeIdentifiers

/// Shared by the app and the share extension: figure out the media behind a link,
/// download it, and save it to Photos.

// MARK: - Storage

enum BentoStorage {
    /// group.<BUNDLE_ID_PREFIX>.bento, from Info.plist (set in Config.xcconfig)
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String ?? "group.bento"

    /// Where the share extension drops finished downloads; the app moves them into Downloads
    static var inbox: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The app's Documents folder (also visible in the Files app under "On My iPhone › Bento")
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloads: URL {
        let url = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves anything the share extension saved into Downloads. Call when the app becomes active.
    static func collectInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fm.moveItem(at: file, to: uniqueURL(in: downloads, name: file.lastPathComponent))
        }
    }

    /// "clip.mp4" -> "clip 2.mp4" if taken
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - Resolving links

struct ResolvedMedia: Sendable {
    enum Kind: Sendable { case video, photo, file }
    let url: URL
    let kind: Kind
    let filename: String
}

enum ResolveError: LocalizedError {
    case noLink
    case unsupported(String)
    case noMedia
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noLink: "That doesn't look like a link."
        case .unsupported(let host): "Can't download from \(host) yet. X/Twitter posts and direct media links work."
        case .noMedia: "That post has no video or photos."
        case .http(let code): "The server said \(code)."
        }
    }
}

enum MediaResolver {
    private static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "gif", "heic", "webp", "mp3", "m4a", "pdf"]

    /// Pulls the first URL out of shared/pasted text
    static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector?.firstMatch(in: trimmed, range: range)?.url
    }

    static func resolve(_ text: String) async throws -> [ResolvedMedia] {
        guard let url = firstURL(in: text) else { throw ResolveError.noLink }
        let host = url.host()?.lowercased() ?? ""

        if ["x.com", "twitter.com", "mobile.twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return try await resolveX(url)
        }
        if mediaExtensions.contains(url.pathExtension.lowercased()) {
            let kind: ResolvedMedia.Kind = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) ? .video
                : ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) ? .photo : .file
            return [ResolvedMedia(url: url, kind: kind, filename: url.lastPathComponent)]
        }
        throw ResolveError.unsupported(host.isEmpty ? "that site" : host)
    }

    // MARK: X / Twitter

    /// Same trick cobalt uses as a fallback: X's public embed ("syndication") endpoint returns
    /// a post's media with no login, given a token derived from the post id.
    private static func resolveX(_ url: URL) async throws -> [ResolvedMedia] {
        guard let match = url.path().firstMatch(of: /status(?:es)?\/(\d+)/) else { throw ResolveError.noMedia }
        let id = String(match.1)

        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "token", value: syndicationToken(id)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResolveError.http(code) }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let user = ((json["user"] as? [String: Any])?["screen_name"] as? String) ?? "x"
        let details = (json["mediaDetails"] as? [[String: Any]]) ?? []

        let media: [ResolvedMedia] = details.enumerated().compactMap { index, m in
            let suffix = details.count > 1 ? "-\(index + 1)" : ""
            switch m["type"] as? String {
            case "video", "animated_gif":
                let variants = ((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]]) ?? []
                let best = variants
                    .filter { ($0["content_type"] as? String) == "video/mp4" }
                    .max { ($0["bitrate"] as? Double ?? 0) < ($1["bitrate"] as? Double ?? 0) }
                guard let s = best?["url"] as? String, let u = URL(string: s) else { return nil }
                return ResolvedMedia(url: u, kind: .video, filename: "\(user)-\(id)\(suffix).mp4")
            case "photo":
                guard let s = m["media_url_https"] as? String,
                      var c = URLComponents(string: s) else { return nil }
                let ext = (s as NSString).pathExtension.isEmpty ? "jpg" : (s as NSString).pathExtension
                c.queryItems = [URLQueryItem(name: "name", value: "orig")]
                return c.url.map { ResolvedMedia(url: $0, kind: .photo, filename: "\(user)-\(id)\(suffix).\(ext)") }
            default:
                return nil
            }
        }
        guard !media.isEmpty else { throw ResolveError.noMedia }
        return media
    }

    /// JS: ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
    static func syndicationToken(_ id: String) -> String {
        let x = (Double(id) ?? 0) / 1e15 * Double.pi
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var intPart = Int(x)
        var frac = x - Double(intPart)
        var s = ""
        repeat {
            s = String(digits[intPart % 36]) + s
            intPart /= 36
        } while intPart > 0
        s += "."
        for _ in 0..<11 {
            frac *= 36
            let d = Int(frac)
            s.append(digits[d])
            frac -= Double(d)
        }
        return s.replacing(/(0+|\.)/, with: "")
    }
}

// MARK: - Downloading

/// Downloads one URL to a folder, reporting progress (0...1)
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!
    private var progress: (@Sendable (Double) -> Void)?

    static func download(_ media: ResolvedMedia, to dir: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let loader = FileDownloader()
        loader.destination = BentoStorage.uniqueURL(in: dir, name: media.filename)
        loader.progress = progress
        let session = URLSession(configuration: .default, delegate: loader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: media.url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            loader.continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            continuation?.resume(throwing: ResolveError.http(code))
            continuation = nil
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Photos

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Bento isn't allowed to add to Photos. Turn it on in Settings › Bento › Photos." }
    }

    static func canSave(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .image)
    }

    static func save(_ file: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        let isVideo = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) ?? false
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
        }
    }
}
