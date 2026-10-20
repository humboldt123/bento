import SwiftUI
import WebKit

struct TaskDetailView: View {
    let item: TodoItem
    let client: NotionTodoClient?
    let onStatus: (TodoStatus) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: TodoStatus
    @State private var html: String?
    @State private var error: String?
    @State private var webHeight: CGFloat = 200

    init(item: TodoItem, client: NotionTodoClient?, onStatus: @escaping (TodoStatus) async -> Void) {
        self.item = item
        self.client = client
        self.onStatus = onStatus
        _status = State(initialValue: TodoStatus(rawValue: item.status) ?? .todo)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.name)
                    .font(.title2.bold())

                HStack(spacing: 8) {
                    if let course = CourseCodes.shared.label(for: item) {
                        Label(course, systemImage: "book.closed")
                    }
                    if let deadline = item.deadline {
                        Label(deadline.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar")
                            .foregroundStyle(deadline < .now ? .red : .secondary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                statusPicker

                Divider()

                if let html {
                    NotionWebView(html: html, height: $webHeight)
                        .id(html.hashValue)
                        .frame(height: webHeight)
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .bentoScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = item.url {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                }
            }
        }
        .task { await loadBody() }
    }

    private var statusPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TodoStatus.allCases, id: \.self) { option in
                    Button {
                        guard option != status else { return }
                        status = option
                        Task {
                            await onStatus(option)
                            if option.isClosed { dismiss() }
                        }
                    } label: {
                        Label(option.label, systemImage: option.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(option == status ? Color.primary : Color.clear, in: Capsule())
                            .foregroundStyle(option == status ? Color(.systemBackground) : .primary)
                            .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(1)
        }
    }

    /// Shows the cached copy right away, then refreshes from Notion
    private func loadBody() async {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notion-\(item.id).html")
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8) {
            html = cached
        }
        guard let client else { return }
        do {
            let fresh = NotionHTML.page(try await client.blocks(pageId: item.id))
            if fresh != html { html = fresh }
            try? fresh.write(to: cacheURL, atomically: true, encoding: .utf8)
        } catch {
            if html == nil { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Rendering

/// Notion blocks -> HTML, with KaTeX for inline ($…$) and block equations
enum NotionHTML {
    static func page(_ blocks: [NotionBlock]) -> String {
        let body = blocks.isEmpty ? "<p class=muted>No notes on this page.</p>" : render(blocks)
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, "Apple Color Emoji", sans-serif;
               margin: 0; line-height: 1.5; word-wrap: break-word; }
        h1, h2, h3 { line-height: 1.25; margin: 1.1em 0 0.4em; }
        p { margin: 0.4em 0; }
        code { font: 0.9em ui-monospace, Menlo; background: rgba(127,127,127,.15); padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(127,127,127,.12); padding: 10px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid rgba(127,127,127,.5); margin: 0.5em 0; padding-left: 10px; }
        .callout { background: rgba(127,127,127,.12); border-radius: 10px; padding: 10px 12px; margin: 0.6em 0; }
        .eq { overflow-x: auto; margin: 0.6em 0; }
        img { max-width: 100%; border-radius: 8px; }
        table { border-collapse: collapse; font-size: 0.9em; display: block; overflow-x: auto; }
        td { border: 1px solid rgba(127,127,127,.35); padding: 4px 8px; }
        details summary { cursor: pointer; }
        .muted { color: gray; }
        a { color: #2f7bf6; }
        </style></head><body>\(body)
        <script>
        document.addEventListener("DOMContentLoaded", function () {
          document.querySelectorAll("[data-tex]").forEach(function (el) {
            try { katex.render(el.dataset.tex, el, { displayMode: el.classList.contains("eq"), throwOnError: false }); } catch (e) {}
          });
          window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
        });
        window.addEventListener("load", function () {
          window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
        });
        </script></body></html>
        """
    }

    static func render(_ blocks: [NotionBlock]) -> String {
        var html = ""
        var listTag: String?

        func closeList() {
            if let tag = listTag { html += "</\(tag)>"; listTag = nil }
        }

        for block in blocks {
            let text = richText(block.payload["rich_text"])
            let kids = block.children.isEmpty ? "" : render(block.children)

            let wantList: String? = block.type == "bulleted_list_item" ? "ul" : block.type == "numbered_list_item" ? "ol" : nil
            if wantList != listTag { closeList() }
            if let wantList, listTag == nil { html += "<\(wantList)>"; listTag = wantList }

            switch block.type {
            case "paragraph": html += "<p>\(text)</p>\(kids)"
            case "heading_1": html += "<h1>\(text)</h1>\(kids)"
            case "heading_2": html += "<h2>\(text)</h2>\(kids)"
            case "heading_3": html += "<h3>\(text)</h3>\(kids)"
            case "bulleted_list_item", "numbered_list_item": html += "<li>\(text)\(kids)</li>"
            case "to_do":
                let checked = (block.payload["checked"] as? Double ?? 0) != 0
                html += "<p>\(checked ? "☑" : "☐") \(text)</p>\(kids)"
            case "quote": html += "<blockquote>\(text)\(kids)</blockquote>"
            case "callout": html += "<div class=callout>\(text)\(kids)</div>"
            case "toggle": html += "<details><summary>\(text)</summary>\(kids)</details>"
            case "code": html += "<pre><code>\(escape(plain(block.payload["rich_text"])))</code></pre>"
            case "equation":
                let tex = block.payload["expression"] as? String ?? ""
                html += "<div class=eq data-tex=\"\(escape(tex))\"></div>"
            case "divider": html += "<hr>"
            case "image":
                let file = (block.payload["file"] as? [String: any Sendable]) ?? (block.payload["external"] as? [String: any Sendable])
                if let url = file?["url"] as? String {
                    html += "<img src=\"\(escape(url))\">"
                    let caption = richText(block.payload["caption"])
                    if !caption.isEmpty { html += "<p class=muted>\(caption)</p>" }
                }
            case "bookmark", "link_preview", "embed":
                if let url = block.payload["url"] as? String {
                    html += "<p><a href=\"\(escape(url))\">\(escape(url))</a></p>"
                }
            case "table":
                html += "<table>\(kids)</table>"
            case "table_row":
                let cells = block.payload["cells"] as? [any Sendable] ?? []
                html += "<tr>" + cells.map { "<td>\(richText($0))</td>" }.joined() + "</tr>"
            case "child_page":
                html += "<p class=muted>📄 \(escape(block.payload["title"] as? String ?? "Page"))</p>"
            default:
                if !text.isEmpty { html += "<p>\(text)</p>" }
                html += kids
            }
        }
        closeList()
        return html
    }

    /// Notion rich_text array -> HTML (bold/italic/code/links, inline equations via KaTeX)
    static func richText(_ value: (any Sendable)?) -> String {
        guard let parts = value as? [any Sendable] else { return "" }
        return parts.compactMap { $0 as? [String: any Sendable] }.map { part in
            if part["type"] as? String == "equation",
               let tex = (part["equation"] as? [String: any Sendable])?["expression"] as? String {
                return "<span data-tex=\"\(escape(tex))\"></span>"
            }
            var s = escape(part["plain_text"] as? String ?? "").replacingOccurrences(of: "\n", with: "<br>")
            let a = part["annotations"] as? [String: any Sendable] ?? [:]
            func on(_ key: String) -> Bool { (a[key] as? Double ?? 0) != 0 }
            if on("code") { s = "<code>\(s)</code>" }
            if on("bold") { s = "<b>\(s)</b>" }
            if on("italic") { s = "<i>\(s)</i>" }
            if on("strikethrough") { s = "<s>\(s)</s>" }
            if on("underline") { s = "<u>\(s)</u>" }
            if let href = part["href"] as? String { s = "<a href=\"\(escape(href))\">\(s)</a>" }
            return s
        }.joined()
    }

    private static func plain(_ value: (any Sendable)?) -> String {
        (value as? [any Sendable] ?? []).compactMap { ($0 as? [String: any Sendable])?["plain_text"] as? String }.joined()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// WKWebView that reports its content height and opens links in Safari
struct NotionWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: URL(string: "https://notion.so"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let height: Binding<CGFloat>

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let h = (message.body as? NSNumber)?.doubleValue, h > 0 else { return }
            height.wrappedValue = CGFloat(h) + 24
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
