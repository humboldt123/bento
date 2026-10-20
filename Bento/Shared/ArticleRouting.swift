import UIKit

/// Where an article link should be read: in an app that claims it (NYT, News…), as an archived copy
/// for paywalled sites, or in Safari. Shared by the read tool and the share extension; each passes
/// its own way of opening URLs.
enum ArticleRouting {
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

    /// `open(url, universalLinksOnly)` returns whether something opened it; nil if nothing did
    @MainActor
    static func open(_ url: URL, using open: (URL, Bool) async -> Bool) async -> Route? {
        if await open(url, true) { return .app }
        if isPaywalled(url), await open(archiveURL(url), false) { return .archive }
        return await open(url, false) ? .safari : nil
    }
}
