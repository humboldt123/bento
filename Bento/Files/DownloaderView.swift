import SwiftUI

/// One link being downloaded
@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case resolving
        case downloading(Double)
        case done(saved: Bool)
        case failed(String)
    }

    let id = UUID()
    let link: String
    var state: State = .resolving
    var files: [URL] = []

    init(link: String) { self.link = link }

    /// cloudFolder: also move finished files there (nil = keep on iPhone)
    func run(saveToPhotos: Bool, cloudFolder: URL? = nil) async {
        do {
            let media = try await MediaResolver.resolve(link)
            var saved = saveToPhotos
            for (i, item) in media.enumerated() {
                let base = Double(i) / Double(media.count)
                state = .downloading(base)
                let file = try await FileDownloader.download(item, to: BentoStorage.downloads) { fraction in
                    Task { @MainActor in
                        self.state = .downloading(base + fraction / Double(media.count))
                    }
                }
                if saveToPhotos, PhotoSaver.canSave(file) {
                    do { try await PhotoSaver.save(file) } catch { saved = false }
                }
                if let cloudFolder {
                    try CloudFolder.transfer(file, to: cloudFolder, move: true)
                    files.append(cloudFolder.appendingPathComponent(file.lastPathComponent))
                } else {
                    files.append(file)
                }
            }
            state = .done(saved: saved)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct DownloaderView: View {
    @AppStorage("downloaderSaveToPhotos") private var saveToPhotos = true
    @AppStorage("downloaderDestination") private var destination = "iphone"
    private let cloud = CloudFolder.shared
    @State private var link = ""
    @State private var jobs: [DownloadJob] = []
    @State private var recent: [FileItem] = []
    @State private var preview: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    input
                    if !jobs.isEmpty { jobList }
                    recentSection
                    tip
                }
                .padding(20)
            }
            .bentoScreen()
            .navigationTitle("downloader")
            .bentoCloseButton()
            .quickLookPreview($preview, in: recent.map(\.url))
            .task { await loadRecent() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadRecent() } }
            }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a link (x.com, twitter.com, .mp4…)", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { start(link) }
                if !link.isEmpty {
                    Button {
                        link = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .bentoCard(cornerRadius: 14)

            Button {
                if link.isEmpty, let pasted = UIPasteboard.general.string {
                    link = pasted
                }
                start(link)
            } label: {
                Label(link.isEmpty ? "Paste & download" : "Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(BentoButtonStyle())

            Toggle("Save to Photos too", isOn: $saveToPhotos)
                .font(.subheadline)
                .tint(.primary)

            if cloud.url != nil {
                Picker("Keep the file on", selection: $destination) {
                    Text("iPhone").tag("iphone")
                    Text(cloud.name).tag("cloud")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(jobs) { job in
                JobRow(job: job)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bentoCard(cornerRadius: 18)
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    NavigationLink("All files") {
                        FileBrowser(folder: BentoStorage.downloads, title: "Downloads")
                    }
                    .font(.subheadline)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(recent.prefix(12)) { item in
                            Button {
                                preview = item.url
                            } label: {
                                Thumbnail(item: item)
                                    .frame(width: 96, height: 128)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .bentoCard(cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                }
                .frame(height: 140)
            }
        }
    }

    private var tip: some View {
        Label {
            Text("From X: tap Share on a post, then **Bento**. It downloads in the background of the share sheet and lands here.")
        } icon: {
            Image(systemName: "square.and.arrow.up")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func start(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let job = DownloadJob(link: trimmed)
        jobs.insert(job, at: 0)
        link = ""
        Task {
            await job.run(saveToPhotos: saveToPhotos, cloudFolder: destination == "cloud" ? cloud.url : nil)
            await loadRecent()
        }
    }

    private func loadRecent() async {
        BentoStorage.collectInbox()
        recent = await FileItem.list(BentoStorage.downloads)
            .filter { !$0.isFolder }
            .sorted { $0.modified > $1.modified }
    }
}

private struct JobRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.link)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            switch job.state {
            case .resolving:
                HStack { ProgressView().controlSize(.small); Text("Finding media…").font(.subheadline) }
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading \(Int(p * 100))%").font(.subheadline) }
                    .tint(.primary)
            case .done(let saved):
                Label(
                    "\(job.files.count == 1 ? job.files[0].lastPathComponent : "\(job.files.count) files")" + (saved ? " · in Photos" : ""),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}
