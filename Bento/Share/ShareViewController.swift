import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Bento" in the share sheet: finds the link, downloads the media, saves it to Photos,
/// and leaves a copy in the app group inbox (the app moves it into Files › Downloads).
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(model: model) { [weak self] in self?.finish() })
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { @MainActor in
            await model.run(items: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            if case .done = model.state {
                try? await Task.sleep(for: .seconds(1.2))
                finish()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State { case working(String), progress(Double), done(String), failed(String) }
    var state: State = .working("Finding the link…")

    func run(items: [NSExtensionItem]) async {
        guard let text = await sharedText(items) else {
            state = .failed("Nothing to download in what was shared.")
            return
        }
        do {
            state = .working("Finding media…")
            let media = try await MediaResolver.resolve(text)
            var savedToPhotos = true
            for (i, item) in media.enumerated() {
                let base = Double(i) / Double(media.count)
                state = .progress(base)
                var file = try await FileDownloader.download(item, to: BentoStorage.inbox) { fraction in
                    Task { @MainActor in self.state = .progress(base + fraction / Double(media.count)) }
                }
                if item.kind == .gif, GifMaker.convertXGifs {
                    state = .working("Making a GIF…")
                    file = (try? await GifMaker.convertDownload(file)) ?? file
                }
                if PhotoSaver.canSave(file) {
                    do {
                        try await PhotoSaver.save(file)
                        try? FileManager.default.removeItem(at: file)  // in Photos now, not also in Files
                    } catch { savedToPhotos = false }
                }
            }
            let what = media.count == 1 ? (media[0].kind == .video ? "Video" : media[0].kind == .gif ? "GIF" : "Photo") : "\(media.count) files"
            state = .done(savedToPhotos ? "\(what) saved to Photos" : "\(what) saved to Bento Files")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// X shares a URL; some apps share the link as text
    private func sharedText(_ items: [NSExtensionItem]) async -> String? {
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.absoluteString
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return text
            }
        }
        return items.compactMap { $0.attributedContentText?.string }.first
    }
}

private struct ShareCard: View {
    let model: ShareModel
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Bento").font(.headline)
                    Spacer()
                    Button("Close", action: close)
                        .font(.subheadline)
                }
                switch model.state {
                case .working(let text):
                    HStack { ProgressView(); Text(text) }
                case .progress(let p):
                    ProgressView(value: p) { Text("Downloading \(Int(p * 100))%") }
                        .tint(.primary)
                case .done(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                case .failed(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            .fontDesign(.rounded)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary, lineWidth: 1.5))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary).offset(x: 3, y: 3))
            .padding(20)
        }
    }
}
