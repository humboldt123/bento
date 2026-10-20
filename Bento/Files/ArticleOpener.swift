import SwiftUI

/// Pasted links that aren't downloadable media are treated as articles: open them in the app that
/// claims the link (NYT, or Apple News when iOS hands it over), else an archived copy for paywalled
/// sites, else Safari.
enum ArticleOpener {
    enum Route: String { case app = "the app", archive = "archive.ph", safari = "Safari" }

    /// Paywalled sites worth sending to an archive when no app opens them
    static let paywalled: Set<String> = [
        "theatlantic.com", "newyorker.com", "wsj.com", "wired.com", "bloomberg.com", "ft.com",
        "economist.com", "washingtonpost.com", "businessinsider.com", "nymag.com", "vanityfair.com",
        "latimes.com", "time.com", "medium.com", "theinformation.com", "foreignpolicy.com",
        "foreignaffairs.com", "technologyreview.com", "scientificamerican.com", "thetimes.co.uk",
    ]

    static func isPaywalled(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return paywalled.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func archiveURL(_ url: URL) -> URL {
        URL(string: "https://archive.ph/newest/" + url.absoluteString)!
    }

    /// Tries each route in order and returns the one that worked
    @MainActor
    static func open(_ url: URL) async -> Route {
        // Universal links only: succeeds when an installed app (NYT, News…) claims this URL
        if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { return .app }
        if isPaywalled(url), await UIApplication.shared.open(archiveURL(url)) { return .archive }
        _ = await UIApplication.shared.open(url)
        return .safari
    }
}

/// Shown after opening an article, with the other ways to read it
struct ArticleCard: View {
    let url: URL
    let route: ArticleOpener.Route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Opened \(url.host() ?? "article") in \(route.rawValue)", systemImage: "newspaper")
                .font(.subheadline.bold())
                .lineLimit(1)
            HStack(spacing: 8) {
                if route != .archive {
                    Button("archive.ph") { UIApplication.shared.open(ArticleOpener.archiveURL(url)) }
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
