import SwiftUI
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Tool root: "On iPhone" (Bento's Downloads, default) or "Cloud" (a folder you picked)
struct FilesView: View {
    @AppStorage("filesLocation") private var location = "iphone"
    @State private var pickingCloud = false
    private let cloud = CloudFolder.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Location", selection: $location) {
                    Label("On iPhone", systemImage: "iphone").tag("iphone")
                    Label("Cloud", systemImage: "icloud").tag("cloud")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if location == "cloud" {
                    if let url = cloud.url {
                        FileBrowser(folder: url, title: cloud.name)
                            .id(url)
                    } else {
                        connectCloud
                    }
                } else {
                    FileBrowser(folder: BentoStorage.downloads, title: "files")
                }
            }
            .background(Color.bentoPaper.ignoresSafeArea())
            .bentoCloseButton()
            .toolbar {
                if location == "cloud", cloud.url != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button { pickingCloud = true } label: { Label("Change cloud folder", systemImage: "folder") }
                            Button(role: .destructive) { cloud.disconnect() } label: { Label("Disconnect", systemImage: "xmark.icloud") }
                        } label: {
                            Image(systemName: "icloud")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $pickingCloud, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { cloud.connect(url) }
            }
        }
    }

    private var connectCloud: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "icloud")
                .font(.system(size: 44))
            Text("Pick a cloud folder")
                .font(.title3.bold())
            Text("Choose any folder in iCloud Drive, Google Drive, OneDrive… Bento remembers it and shows what's inside here, without copying it to your iPhone. You can move files between this phone and that folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                pickingCloud = true
            } label: {
                Label("Choose folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(BentoButtonStyle())
            Spacer()
        }
        .padding(28)
        .navigationTitle("files")
    }
}

// MARK: - Model

struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let isFolder: Bool
    let size: Int64
    let modified: Date
    /// iCloud file that isn't downloaded yet (".name.ext.icloud" on disk)
    var isCloudPlaceholder = false

    var name: String {
        let raw = url.lastPathComponent
        guard isCloudPlaceholder else { return raw }
        return String(raw.dropFirst().dropLast(".icloud".count))
    }
    var type: UTType? { UTType(filenameExtension: (name as NSString).pathExtension) }

    var symbol: String {
        if isFolder { return "folder.fill" }
        if isCloudPlaceholder { return "icloud.and.arrow.down" }
        guard let type else { return "doc" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        return "doc"
    }

    /// Lists a folder off the main thread; only asks the filesystem for the keys we show
    static func list(_ folder: URL) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
            return urls.compactMap { url in
                let raw = url.lastPathComponent
                let placeholder = raw.hasPrefix(".") && raw.hasSuffix(".icloud")
                // Other hidden files stay hidden
                if raw.hasPrefix(".") && !placeholder { return nil }
                let v = try? url.resourceValues(forKeys: Set(keys))
                return FileItem(url: url, isFolder: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0),
                                modified: v?.contentModificationDate ?? .distantPast, isCloudPlaceholder: placeholder)
            }
        }.value
    }
}

enum FileSort: String, CaseIterable {
    case newest = "Newest", name = "Name", size = "Size"
}

// MARK: - Browser

struct FileBrowser: View {
    let folder: URL
    let title: String

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("filesGrid") private var grid = true
    @AppStorage("filesSort") private var sort = FileSort.newest
    @State private var items: [FileItem] = []
    @State private var search = ""
    @State private var preview: URL?
    @State private var renaming: FileItem?
    @State private var newName = ""
    @State private var showNewFolder = false
    @State private var showImporter = false
    @State private var message: String?

    private var visible: [FileItem] {
        let filtered = search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let sorted: [FileItem]
        switch sort {
        case .newest: sorted = filtered.sorted { $0.modified > $1.modified }
        case .name: sorted = filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: sorted = filtered.sorted { $0.size > $1.size }
        }
        // Folders first
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    private var previewables: [URL] { visible.filter { !$0.isFolder && !$0.isCloudPlaceholder }.map(\.url) }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder", description: Text("Downloads and imported files show up here."))
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 14) {
                        ForEach(visible) { item in
                            cell(item) { GridCell(item: item) }
                        }
                    }
                    .padding()
                }
            } else {
                List(visible) { item in
                    cell(item) { RowCell(item: item) }
                }
                .listStyle(.plain)
            }
        }
        .bentoScreen()
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Search \(title)")
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("View", selection: $grid) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(true)
                        Label("List", systemImage: "list.bullet").tag(false)
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { showImporter = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .quickLookPreview($preview, in: previewables)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.copyItem(at: url, to: BentoStorage.uniqueURL(in: folder, name: url.lastPathComponent))
            }
            Task { await reload() }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                try? FileManager.default.createDirectory(at: BentoStorage.uniqueURL(in: folder, name: name), withIntermediateDirectories: false)
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let item = renaming, !newName.isEmpty, newName != item.name {
                    try? FileManager.default.moveItem(at: item.url, to: folder.appendingPathComponent(newName))
                }
                renaming = nil
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .bentoCard(cornerRadius: 14)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func cell<Content: View>(_ item: FileItem, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if item.isFolder {
                NavigationLink {
                    FileBrowser(folder: item.url, title: item.name)
                } label: {
                    content()
                }
            } else if item.isCloudPlaceholder {
                Button {
                    // The real file name is the placeholder without its dot and ".icloud"
                    let real = item.url.deletingLastPathComponent().appendingPathComponent(item.name)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                    flash("Downloading \(item.name)…")
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        await reload()
                    }
                } label: {
                    content()
                }
            } else {
                Button {
                    preview = item.url
                } label: {
                    content()
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !item.isFolder {
                ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                if PhotoSaver.canSave(item.url) {
                    Button {
                        Task {
                            do {
                                try await PhotoSaver.save(item.url)
                                flash("Saved to Photos")
                            } catch {
                                flash(error.localizedDescription)
                            }
                        }
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                    }
                }
            }
            if !item.isCloudPlaceholder, let target = transferTarget {
                Button {
                    do {
                        try CloudFolder.transfer(item.url, to: target.folder, move: true)
                        items.removeAll { $0.id == item.id }
                        flash("Moved to \(target.label)")
                    } catch {
                        flash(error.localizedDescription)
                    }
                } label: {
                    Label("Move to \(target.label)", systemImage: target.symbol)
                }
            }
            Button {
                newName = item.name
                renaming = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                try? FileManager.default.removeItem(at: item.url)
                items.removeAll { $0.id == item.id }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Files on iPhone can move to the cloud folder and vice versa
    private var transferTarget: (folder: URL, label: String, symbol: String)? {
        guard let cloud = CloudFolder.shared.url else { return nil }
        if folder.path.hasPrefix(cloud.path) {
            return (BentoStorage.downloads, "iPhone", "iphone")
        }
        return (cloud, CloudFolder.shared.name, "icloud.and.arrow.up")
    }

    private func reload() async {
        if folder == BentoStorage.documents || folder == BentoStorage.downloads {
            BentoStorage.collectInbox()
            _ = BentoStorage.downloads
        }
        items = await FileItem.list(folder)
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { message = nil }
        }
    }
}

// MARK: - Cells

private struct GridCell: View {
    let item: FileItem

    var body: some View {
        VStack(spacing: 6) {
            Thumbnail(item: item)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .bentoCard(cornerRadius: 14)
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !item.isFolder {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RowCell: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.isFolder ? "Folder" : "\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isFolder {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// QuickLook thumbnail, generated only when the cell is on screen and cached by path + date
struct Thumbnail: View {
    let item: FileItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                // Overlay on a clear view so a fill-scaled image can't grow the cell
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
            } else {
                Image(systemName: item.symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            if item.type?.conforms(to: .movie) == true {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.black.opacity(0.5), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .task(id: item.url) {
            guard !item.isFolder, !item.isCloudPlaceholder else { return }
            image = await ThumbnailCache.shared.thumbnail(for: item)
        }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func thumbnail(for item: FileItem) async -> UIImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 220, height: 220),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.uiImage, forKey: key)
        return rep.uiImage
    }
}
