import Foundation
import Observation

/// The "Cloud" side of Files: a folder you picked once from the system picker (iCloud Drive,
/// Google Drive, OneDrive…), remembered with a security-scoped bookmark.
@MainActor
@Observable
final class CloudFolder {
    static let shared = CloudFolder()

    private static let key = "cloudFolderBookmark"
    private(set) var url: URL?

    var name: String { url?.lastPathComponent ?? "Cloud" }

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        var stale = false
        if let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
            _ = resolved.startAccessingSecurityScopedResource()
            url = resolved
            if stale { save(resolved) }
        }
    }

    /// Call with the folder URL from the folder picker
    func connect(_ picked: URL) {
        url?.stopAccessingSecurityScopedResource()
        _ = picked.startAccessingSecurityScopedResource()
        url = picked
        save(picked)
    }

    func disconnect() {
        url?.stopAccessingSecurityScopedResource()
        url = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func save(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Moves (or copies) a file between iPhone and the cloud folder
    static func transfer(_ file: URL, to folder: URL, move: Bool) throws {
        let dest = BentoStorage.uniqueURL(in: folder, name: file.lastPathComponent)
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { target in
            do {
                if move { try FileManager.default.moveItem(at: file, to: target) }
                else { try FileManager.default.copyItem(at: file, to: target) }
            } catch {
                thrown = error
            }
        }
        if let error = coordError ?? thrown { throw error }
    }
}
