import AVFoundation
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

    /// Settings both the app and the share extension read
    static var groupDefaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

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
    /// gif: X's "GIFs", which are silent MP4s we can turn back into real GIFs
    enum Kind: Sendable { case video, gif, photo, file }
    let url: URL
    let kind: Kind
    let filename: String
    /// YouTube: separate audio stream, combined with the video after download
    var audioURL: URL? = nil
    /// YouTube: stream sizes, so they can be fetched in ranges (one big request gets throttled)
    var videoBytes: Int64? = nil
    var audioBytes: Int64? = nil
    /// YouTube: real length in seconds (the downloaded streams' headers can claim double)
    var seconds: Double? = nil
}

enum ResolveError: LocalizedError {
    case noLink
    case unsupported(String)
    case noMedia
    case http(Int)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .noLink: "That doesn't look like a link."
        case .unsupported(let host): "Can't download from \(host) yet. X, Instagram, YouTube and direct media links work."
        case .noMedia: "That post has no video or photos."
        case .http(let code): "The server said \(code)."
        case .blocked(let why): why
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

    private static let xHosts = ["x.com", "twitter.com", "mobile.twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com"]

    private static let igHosts = ["instagram.com", "instagr.am", "ddinstagram.com", "kkinstagram.com"]
    private static let ytHosts = ["youtube.com", "youtu.be", "youtube-nocookie.com"]

    private static func host(_ url: URL, in hosts: [String]) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether Bento can download media from this link (otherwise it's probably an article)
    static func handles(_ url: URL) -> Bool {
        host(url, in: xHosts + igHosts + ytHosts) || mediaExtensions.contains(url.pathExtension.lowercased())
    }

    static func resolve(_ text: String) async throws -> [ResolvedMedia] {
        guard let url = firstURL(in: text) else { throw ResolveError.noLink }
        let host = url.host()?.lowercased() ?? ""

        if Self.host(url, in: xHosts) { return try await resolveX(url) }
        if Self.host(url, in: igHosts) { return try await resolveInstagram(url) }
        if Self.host(url, in: ytHosts) { return try await resolveYouTube(url) }
        if mediaExtensions.contains(url.pathExtension.lowercased()) {
            let kind: ResolvedMedia.Kind = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) ? .video
                : ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) ? .photo : .file
            return [ResolvedMedia(url: url, kind: kind, filename: url.lastPathComponent)]
        }
        throw ResolveError.unsupported(host.isEmpty ? "that site" : host)
    }

    // MARK: X / Twitter

    /// Works as of 10/21/26. If X downloads break, this endpoint or its token changed; check cobalt's
    /// api/src/processing/services/twitter.js for the current approach.
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
                let kind: ResolvedMedia.Kind = m["type"] as? String == "animated_gif" ? .gif : .video
                return ResolvedMedia(url: u, kind: kind, filename: "\(user)-\(id)\(suffix).mp4")
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

    // MARK: Instagram

    /// Works as of 10/21/26 (tested on a reel, incl. username/reel/ID?igsh=… links). If Instagram
    /// breaks, compare with cobalt's instagram.js: the embed page's "init"/contextJSON shape may have
    /// changed. As of that date the mobile API (/media/ID/info) and GraphQL both need a login.
    /// Ported from cobalt (api/src/processing/services/instagram.js). Without a login the only path
    /// that still works is the post's embed page, which carries the post's data as JSON. Share links
    /// (instagram.com/share/…) redirect to the real post, but only for a non-browser user agent.
    private static func resolveInstagram(_ url: URL) async throws -> [ResolvedMedia] {
        // Path shapes cobalt accepts, plus the reels/ and username-prefixed ones the app shares:
        // p/ID, tv/ID, reel/ID, reels/ID, USER/p/ID, USER/reel/ID, share/ID, share/p/ID, share/reel/ID
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let postKinds: Set<String> = ["p", "tv", "reel", "reels"]

        if parts.first == "stories" { throw ResolveError.blocked("Instagram stories need a login, so Bento can't get them.") }
        if parts.count >= 2, parts[0] == "reels", parts[1] == "audio" { throw ResolveError.noMedia }
        if parts.first == "share", let id = parts.dropFirst().last(where: { !postKinds.contains($0) }) {
            let target = try await redirectTarget(URL(string: "https://www.instagram.com/share/\(id)/")!)
            guard host(target, in: igHosts), target.pathComponents.first(where: { $0 != "/" }) != "share" else {
                throw ResolveError.blocked("Instagram didn't say which post that share link is for.")
            }
            return try await resolveInstagram(target)
        }
        guard let k = parts.firstIndex(where: postKinds.contains), k <= 1, k + 1 < parts.count else {
            throw ResolveError.blocked("That Instagram link isn't a post or reel.")
        }
        let shortcode = parts[k + 1]

        var request = URLRequest(url: URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/")!)
        for (key, value) in browserHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResolveError.http(code) }
        let html = String(decoding: data, as: UTF8.self)

        // The page boots with ["init",[],[{…,"contextJSON":"<post as JSON>"}]],
        guard let match = html.firstMatch(of: /"init",\[\],\[(.*?)\]\],/),
              let boot = try? JSONSerialization.jsonObject(with: Data(match.1.utf8)) as? [String: Any],
              let contextJSON = boot["contextJSON"] as? String,
              let context = try? JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [String: Any],
              let gql = context["gql_data"] as? [String: Any],
              let post = (gql["shortcode_media"] ?? gql["xdt_shortcode_media"]) as? [String: Any] else {
            throw ResolveError.blocked("Instagram won't show this post without a login (it may be private or age-restricted).")
        }

        let user = (post["owner"] as? [String: Any])?["username"] as? String ?? "instagram"
        func item(_ node: [String: Any], suffix: String) -> ResolvedMedia? {
            if node["is_video"] as? Bool == true, let s = node["video_url"] as? String, let u = URL(string: s) {
                return ResolvedMedia(url: u, kind: .video, filename: "\(user)-\(shortcode)\(suffix).mp4")
            }
            if let s = node["display_url"] as? String, let u = URL(string: s) {
                return ResolvedMedia(url: u, kind: .photo, filename: "\(user)-\(shortcode)\(suffix).jpg")
            }
            return nil
        }
        // Carousels ("sidecar"): every slide; otherwise the one video or photo
        let edges = ((post["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        let media = edges.isEmpty
            ? [item(post, suffix: "")].compactMap { $0 }
            : edges.enumerated().compactMap { i, e in (e["node"] as? [String: Any]).flatMap { item($0, suffix: "-\(i + 1)") } }
        guard !media.isEmpty else { throw ResolveError.noMedia }
        return media
    }

    private static let browserHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-GB,en;q=0.9",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
    ]

    /// Where a link redirects to, without following it. Instagram only redirects for a curl-like agent.
    private static func redirectTarget(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("curl/7.88.1", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL else { throw ResolveError.noMedia }
        return target
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: YouTube

    /// Works as of 10/21/26 (1080p + AAC, Shorts/live/youtu.be links). If YouTube breaks, the
    /// ANDROID_VR client probably needs a newer clientVersion or now wants a PO token; check which
    /// clients yt-dlp currently defaults to (yt_dlp/extractor/youtube) and swap in one that returns plain URLs.
    /// cobalt uses youtubei.js, which needs a JS engine and proof-of-origin tokens. The Android VR
    /// client of YouTube's own player API (also used by yt-dlp) still returns plain stream URLs
    /// without either, so this asks it directly: best H.264 video up to 1080p plus AAC audio,
    /// combined into one MP4 after download.
    private static func resolveYouTube(_ url: URL) async throws -> [ResolvedMedia] {
        guard let id = youTubeID(url) else { throw ResolveError.blocked("That YouTube link doesn't point at a video.") }

        let client: [String: Any] = [
            "clientName": "ANDROID_VR", "clientVersion": "1.60.19", "deviceMake": "Oculus", "deviceModel": "Quest 3",
            "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L", "hl": "en", "gl": "US",
        ]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(youTubeAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client], "videoId": id, "contentCheckOk": true, "racyCheckOk": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResolveError.http(code) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let status = json["playabilityStatus"] as? [String: Any]
        guard status?["status"] as? String == "OK" else {
            throw ResolveError.blocked("YouTube: \(status?["reason"] as? String ?? "this video can't be downloaded").")
        }
        let title = (json["videoDetails"] as? [String: Any])?["title"] as? String ?? id
        let name = safeFilename(title, fallback: id) + ".mp4"
        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []

        func size(_ f: [String: Any]) -> Int64? { (f["contentLength"] as? String).flatMap { Int64($0) } }
        func mime(_ f: [String: Any]) -> String { f["mimeType"] as? String ?? "" }
        let video = adaptive
            .filter { mime($0).hasPrefix("video/mp4") && mime($0).contains("avc1") && ($0["height"] as? Int ?? 0) <= 1080 && size($0) != nil }
            .max { ($0["height"] as? Int ?? 0, $0["bitrate"] as? Int ?? 0) < ($1["height"] as? Int ?? 0, $1["bitrate"] as? Int ?? 0) }
        let audio = adaptive
            .filter { mime($0).hasPrefix("audio/mp4") && size($0) != nil }
            .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }

        if let video, let audio, let v = (video["url"] as? String).flatMap(URL.init(string:)),
           let a = (audio["url"] as? String).flatMap(URL.init(string:)) {
            let seconds = (video["approxDurationMs"] as? String).flatMap(Double.init).map { $0 / 1000 }
            return [ResolvedMedia(url: v, kind: .video, filename: name, audioURL: a, videoBytes: size(video),
                                  audioBytes: size(audio), seconds: seconds)]
        }
        // Fallback: the single 360p stream with sound built in
        let muxed = (streaming["formats"] as? [[String: Any]] ?? []).first { $0["url"] != nil }
        guard let muxed, let u = (muxed["url"] as? String).flatMap(URL.init(string:)) else { throw ResolveError.noMedia }
        return [ResolvedMedia(url: u, kind: .video, filename: name, videoBytes: size(muxed))]
    }

    static let youTubeAgent = "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    /// The 11-character id from watch?v=, youtu.be/, shorts/, live/, embed/ and v/ links
    /// (youtu.be links can carry junk after the id, e.g. youtu.be/ID//x)
    static func youTubeID(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let candidate: String?
        if url.host()?.lowercased().hasSuffix("youtu.be") == true {
            candidate = parts.first
        } else if let v = query.first(where: { $0.name == "v" })?.value {
            candidate = v
        } else if parts.count >= 2, ["shorts", "live", "embed", "v", "e"].contains(parts[0]) {
            candidate = parts[1]
        } else {
            candidate = nil
        }
        guard let id = candidate.map({ String($0.prefix(11)) }), id.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil else { return nil }
        return id
    }

    private static func safeFilename(_ s: String, fallback: String) -> String {
        let cleaned = s.replacing(/[\/\\:*?"<>|\n]+/, with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
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
        if let videoBytes = media.videoBytes {
            return try await YouTubeDownload.run(media, videoBytes: videoBytes, to: dir, progress: progress)
        }
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

/// YouTube streams: fetched as 10 MB ranges, four at a time (a single request is throttled to
/// well under 1 MB/s), then the separate video and audio are combined without re-encoding.
enum YouTubeDownload {
    static func run(_ media: ResolvedMedia, videoBytes: Int64, to dir: URL,
                    progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let total = videoBytes + (media.audioBytes ?? 0)
        let done = Counter()
        let report: @Sendable (Int64) -> Void = { n in progress?(min(1, Double(done.add(n)) / Double(max(total, 1)))) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoFile = tmp.appendingPathComponent("video.mp4")
        try await fetch(media.url, bytes: videoBytes, to: videoFile, report: report)
        let out = BentoStorage.uniqueURL(in: dir, name: media.filename)
        guard let audioURL = media.audioURL, let audioBytes = media.audioBytes else {
            try FileManager.default.moveItem(at: videoFile, to: out)
            return out
        }
        let audioFile = tmp.appendingPathComponent("audio.m4a")
        try await fetch(audioURL, bytes: audioBytes, to: audioFile, report: report)
        try await mux(video: videoFile, audio: audioFile, seconds: media.seconds, to: out)
        return out
    }

    private final class Counter: @unchecked Sendable {
        private var value: Int64 = 0
        private let lock = NSLock()
        func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; value += n; return value }
    }

    private static func fetch(_ url: URL, bytes: Int64, to file: URL, report: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk: Int64 = 10 << 20
        let starts = Array(stride(from: Int64(0), to: bytes, by: Int(chunk)))

        try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
            var next = 0
            func add() {
                guard next < starts.count else { return }
                let start = starts[next]
                next += 1
                group.addTask {
                    let end = min(start + chunk, bytes) - 1
                    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(start)-\(end)")]
                    var request = URLRequest(url: c.url!)
                    request.setValue(MediaResolver.youTubeAgent, forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else { throw ResolveError.http(code) }
                    return (start, data)
                }
            }
            for _ in 0..<4 { add() }
            while let (start, data) = try await group.next() {
                try handle.seek(toOffset: UInt64(start))
                try handle.write(contentsOf: data)
                report(Int64(data.count))
                add()
            }
        }
    }

    private static func mux(video: URL, audio: URL, seconds: Double?, to out: URL) async throws {
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vTrack = try await v.loadTracks(withMediaType: .video).first,
              let aTrack = try await a.loadTracks(withMediaType: .audio).first else { throw ResolveError.noMedia }
        // YouTube's DASH files are fragmented MP4s that AVFoundation reads as twice their real length
        // (every frame is timed right, the total isn't), so cut to the length YouTube reports
        var duration = min(try await vTrack.load(.timeRange).duration, try await aTrack.load(.timeRange).duration)
        if let seconds { duration = min(duration, CMTime(seconds: seconds, preferredTimescale: 600)) }

        let composition = AVMutableComposition()
        let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: .zero)
        cv?.preferredTransform = try await vTrack.load(.preferredTransform)
        let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ResolveError.noMedia
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw ResolveError.noMedia }
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
            let request = isVideo
                ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            // Files carry the original post's date; file them under when they were saved instead
            request?.creationDate = .now
        }
    }
}
