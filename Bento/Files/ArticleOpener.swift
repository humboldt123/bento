import SwiftUI

/// The app's way of opening article links
enum ArticleOpener {
    @MainActor
    static func open(_ url: URL) async -> ArticleRouting.Route {
        await ArticleRouting.open(url) { u, appOnly in
            await UIApplication.shared.open(u, options: appOnly ? [.universalLinksOnly: true] : [:])
        } ?? .safari
    }
}

/// read: paste an article link, read it where it reads best
struct ReadView: View {
    @State private var link = ""
    @State private var opened: [(url: URL, route: ArticleRouting.Route)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField("Paste an article link", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { go(link) }
                    }
                    .padding(14)
                    .bentoCard(cornerRadius: 16)

                    Button {
                        if link.isEmpty, let pasted = UIPasteboard.general.string { go(pasted) } else { go(link) }
                    } label: {
                        Label(link.isEmpty ? "Paste & read" : "Read", systemImage: "book")
                    }
                    .buttonStyle(BentoButtonStyle())

                    ForEach(Array(opened.enumerated()), id: \.offset) { _, item in
                        ArticleCard(url: item.url, route: item.route)
                    }

                    Label {
                        Text("Opens in the publisher's app if you have it (NYT, News), otherwise an archived copy for paywalled sites, otherwise Safari. You can also share an article to **Bento** from Safari or X.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .bentoScreen()
            .navigationTitle("read")
            .bentoCloseButton()
        }
    }

    private func go(_ text: String) {
        guard let url = MediaResolver.firstURL(in: text) else { return }
        link = ""
        Task {
            let route = await ArticleOpener.open(url)
            opened.insert((url, route), at: 0)
        }
    }
}

/// Shown after opening an article, with the other ways to read it
struct ArticleCard: View {
    let url: URL
    let route: ArticleRouting.Route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Opened \(url.host() ?? "article") in \(route.rawValue)", systemImage: "newspaper")
                .font(.subheadline.bold())
                .lineLimit(1)
            HStack(spacing: 8) {
                if route != .archive {
                    Button("archive.ph") { UIApplication.shared.open(ArticleRouting.archiveURL(url)) }
                }
                if route != .safari {
                    Button("Safari") { UIApplication.shared.open(url) }
                }
                Button("Copy link") { UIPasteboard.general.url = url }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bentoCard(cornerRadius: 16)
    }
}
