import SwiftUI
import WebKit

/// The expression being built plus the tile bank, both rendered with KaTeX in one web view.
/// Taps come back as events; state lives in Swift and is pushed in with `update(...)`.
struct ExprBoard: UIViewRepresentable {
    enum Event {
        case tile(Int)
        case info(Int)
        case slot(String)
        case node(String)
        case background
    }

    struct Tile {
        let tex: String
        let enabled: Bool
    }

    /// TeX of the expression, with \htmlId markers on slots ("s-…") and nodes ("n-…")
    let expression: String
    let tiles: [Tile]
    /// "right" / "wrong" / nil
    let verdict: String?
    @Binding var height: CGFloat
    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "board")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.loadHTMLString(Self.page, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push()
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "board")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ExprBoard
        weak var webView: WKWebView?
        private var loaded = false
        private var lastPayload = ""

        init(_ parent: ExprBoard) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            lastPayload = ""
            push()
        }

        func push() {
            guard loaded, let webView else { return }
            let payload: [String: Any] = [
                "expr": parent.expression,
                "tiles": parent.tiles.map { ["tex": $0.tex, "on": $0.enabled] },
                "verdict": parent.verdict ?? "",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8), json != lastPayload else { return }
            lastPayload = json
            webView.evaluateJavaScript("update(\(json))")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "height":
                if let h = (body["value"] as? NSNumber)?.doubleValue, abs(parent.height - h) > 0.5 {
                    parent.height = CGFloat(h)
                }
            case "tile": if let i = body["i"] as? Int { parent.onEvent(.tile(i)) }
            case "info": if let i = body["i"] as? Int { parent.onEvent(.info(i)) }
            case "slot": if let id = body["id"] as? String { parent.onEvent(.slot(id)) }
            case "node": if let id = body["id"] as? String { parent.onEvent(.node(id)) }
            default: parent.onEvent(.background)
            }
        }
    }

    // MARK: - Page

    static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <style>
    :root { color-scheme: light dark; --ink: #000; --card: #fff; --muted: #888; }
    @media (prefers-color-scheme: dark) { :root { --ink: #fff; --card: #1c1c1e; } }
    html, body { margin: 0; background: transparent; -webkit-user-select: none; -webkit-touch-callout: none; }
    body { font: 16px ui-rounded, -apple-system, "Apple Color Emoji"; color: var(--ink); padding: 4px 4px 8px; display: flow-root; }
    .card { background: var(--card); border: 1.5px solid var(--ink); border-radius: 20px; box-shadow: 3px 3px 0 var(--ink);
            padding: 18px 14px; min-height: 64px; display: flex; align-items: center; justify-content: center;
            overflow-x: auto; transition: background .15s; }
    .card.right { background: rgba(34,173,84,.14); }
    .card.wrong { background: rgba(255,59,48,.10); }
    #expr .katex { font-size: 1.35em; }
    .hint { color: var(--muted); font-size: 14px; margin: 8px 4px 14px; text-align: center; }
    #bank { display: flex; flex-wrap: wrap; gap: 9px; }
    .tile { background: var(--card); border: 1.3px solid var(--ink); border-radius: 12px; box-shadow: 2px 2px 0 var(--ink);
            padding: 8px 12px; min-width: 20px; text-align: center; }
    .tile:active { transform: translate(2px, 2px); box-shadow: none; }
    .tile.off { opacity: .25; }
    .tile .katex { font-size: 1.12em; }
    /* KaTeX stacks invisible struts over fractions; only real glyphs, boxes and bars take taps */
    #expr .katex, #expr .katex * { pointer-events: none; }
    #expr .katex span:not(:has(span)):not(.strut):not(.pstrut):not(.vlist-s),
    #expr .fbox, #expr .frac-line, #expr svg { pointer-events: auto; }
    #expr .fbox { padding: 4px 6px !important; }
    .selnode { background: rgba(255,59,48,.16); border-radius: 6px; box-shadow: 0 0 0 2px rgba(255,59,48,.55); }
    [id^="s-"] { cursor: pointer; }
    [id^="n-"]:active { opacity: .5; }
    </style></head><body>
    <div id="expr" class="card"></div>
    <div class="hint" id="hint">tap a box to aim · tap a piece to select it · hold a tile for its meaning</div>
    <div id="bank"></div>
    <script>
    function post(m) { window.webkit.messageHandlers.board.postMessage(m); }
    function tex(el, s, display) {
      try { katex.render(s, el, { displayMode: display, throwOnError: false, trust: true, strict: false }); }
      catch (e) { el.textContent = s; }
    }
    function measure() { post({ type: "height", value: Math.ceil(document.body.getBoundingClientRect().height) }); }
    function update(state) {
      var expr = document.getElementById("expr");
      tex(expr, state.expr, true);
      expr.className = "card " + (state.verdict || "");
      var bank = document.getElementById("bank");
      bank.innerHTML = "";
      state.tiles.forEach(function (t, i) {
        var b = document.createElement("div");
        b.className = "tile" + (t.on ? "" : " off");
        b.dataset.i = i;
        tex(b, t.tex, false);
        bank.appendChild(b);
      });
      measure();
    }
    // Taps are handled on touchend (click is unreliable in a non-scrolling WKWebView);
    // innermost slot or node wins; holding a tile asks for its meaning
    var pressTimer = null, longPressed = false, moved = false, startX = 0, startY = 0, lastFire = 0;
    function act(target) {
      var now = Date.now();
      if (now - lastFire < 250) return;  // one gesture, one action
      lastFire = now;
      var tile = target.closest(".tile");
      if (tile) { if (!tile.classList.contains("off")) post({ type: "tile", i: +tile.dataset.i }); return; }
      var hit = target.closest('[id^="s-"], [id^="n-"]');
      if (hit) { post({ type: hit.id[0] === "s" ? "slot" : "node", id: hit.id.slice(2) }); return; }
      if (target.closest("#expr")) post({ type: "background" });
    }
    document.addEventListener("touchstart", function (e) {
      var t = e.touches[0];
      startX = t.clientX; startY = t.clientY; moved = false; longPressed = false;
      var tile = e.target.closest(".tile");
      if (tile) {
        pressTimer = setTimeout(function () { longPressed = true; post({ type: "info", i: +tile.dataset.i }); }, 550);
      }
    }, { passive: true });
    document.addEventListener("touchmove", function (e) {
      var t = e.touches[0];
      if (Math.abs(t.clientX - startX) > 8 || Math.abs(t.clientY - startY) > 8) { moved = true; clearTimeout(pressTimer); }
    }, { passive: true });
    document.addEventListener("touchend", function (e) {
      clearTimeout(pressTimer);
      if (moved || longPressed) return;
      e.preventDefault();  // no ghost click afterwards
      act(e.target);
    });
    document.addEventListener("click", function (e) { act(e.target); });  // pointer devices
    if (window.ResizeObserver) new ResizeObserver(measure).observe(document.body);
    if (document.fonts) document.fonts.ready.then(measure);
    </script></body></html>
    """
}
