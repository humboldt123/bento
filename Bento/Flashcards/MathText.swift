import SwiftUI
import WebKit

/// Card text with real math: $inline$ and $$display$$ TeX via KaTeX, plus **bold**, *italic*, `code`
/// and line breaks. Sizes itself to its content; taps pass through to the card.
struct MathText: View {
    let text: String
    var size: CGFloat = 17
    var bold = false

    @State private var height: CGFloat = 24

    init(_ text: String, size: CGFloat = 17, bold: Bool = false) {
        self.text = text
        self.size = size
        self.bold = bold
    }

    var body: some View {
        MathWebView(html: MathHTML.page(text, size: size, bold: bold), height: $height)
            .frame(height: height)
            .accessibilityLabel(text)
    }
}

enum MathHTML {
    static func page(_ text: String, size: CGFloat, bold: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; height: auto; }
        body { display: flow-root; }
        body { font: \(bold ? "700" : "400") \(Int(size))px ui-rounded, -apple-system, system-ui, "Apple Color Emoji"; line-height: 1.4;
               -webkit-text-size-adjust: none; word-wrap: break-word; }
        p { margin: 0 0 0.6em; } p:last-child { margin-bottom: 0; }
        pre { margin: 0.5em 0; padding: 10px 12px; background: rgba(127,127,127,.12); border-radius: 10px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: .8em; font-weight: 500; line-height: 1.5; white-space: pre; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: .86em; font-weight: \(bold ? 600 : 500);
               background: rgba(127,127,127,.15); padding: 1px 5px; border-radius: 5px; -webkit-box-decoration-break: clone; }
        .katex { font-size: 1.08em; }
        .katex-display { margin: 0.4em 0; overflow-x: auto; overflow-y: hidden; }
        </style></head><body>\(body(text))
        <script>
        // Shrink wide display equations to fit (down to 60%), then let them scroll
        function fit() {
          document.querySelectorAll(".katex-display").forEach(function (d) {
            var k = d.querySelector(".katex"); if (!k) return;
            k.style.fontSize = "";
            var ratio = d.clientWidth / k.scrollWidth;
            if (ratio < 1) k.style.fontSize = (1.08 * Math.max(0.6, ratio * 0.94)) + "em";
          });
        }
        window.addEventListener("load", function () { fit(); done(); });
        if (document.fonts) { document.fonts.ready.then(function () { fit(); done(); }); }
        function done() {
          var h = Math.ceil(document.body.getBoundingClientRect().height);
          window.webkit.messageHandlers.height.postMessage(h);
        }
        function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
        // Code reads as code, not a wall of Courier: spaces don't break, so a snippet only wraps
        // after "; " or ", " (statement / argument), or after "(" and "." when it has to
        function codeBreaks() {
          document.body.querySelectorAll(":not(pre) > code").forEach(function (c) {
            c.innerHTML = c.textContent.split(/(?<=[;,]) /).map(function (seg) {
              return seg.split(/(?<=[(.])/).map(function (p) { return esc(p).replace(/ /g, "&nbsp;"); }).join("<wbr>");
            }).join(" ");
          });
        }
        codeBreaks();
        try {
          document.querySelectorAll("[data-tex]").forEach(function (el) {
            katex.render(el.dataset.tex, el, { displayMode: el.tagName === "DIV", throwOnError: false });
          });
        } catch (e) {}
        fit();
        done();
        window.addEventListener("load", done);
        if (document.fonts) { document.fonts.ready.then(done); }
        // Catches KaTeX CSS and fonts arriving after the first measurement
        if (window.ResizeObserver) { new ResizeObserver(done).observe(document.body); }
        </script></body></html>
        """
    }

    /// Markdown-lite -> HTML, with math pulled out first so `*` and `_` inside TeX survive
    static func body(_ text: String) -> String {
        var math: [String] = []
        func stash(_ html: String) -> String {
            math.append(html)
            return "\u{E000}\(math.count - 1)\u{E001}"
        }

        var s = text
        // ```fenced``` blocks first, as their own paragraph, so $ and * inside stay literal
        var blocks: [String] = []
        s = s.replacing(/\n*```[^\n]*\n([\s\S]*?)\n?```\n*/) { m in
            blocks.append("<pre><code>\(escape(String(m.1)))</code></pre>")
            return "\n\n\u{E002}\(blocks.count - 1)\u{E003}\n\n"
        }
        s = s.trimmingCharacters(in: .newlines)
        s = s.replacing(/\$\$([\s\S]+?)\$\$/) { m in stash("<div data-tex=\"\(escape(String(m.1)))\"></div>") }
        s = s.replacing(/\$([^$\n]+?)\$/) { m in stash("<span data-tex=\"\(escape(String(m.1)))\"></span>") }

        s = escape(s)
        s = s.replacing(/`([^`]+)`/) { m in "<code>\(m.1)</code>" }
        s = s.replacing(/\*\*([^*]+)\*\*/) { m in "<b>\(m.1)</b>" }
        s = s.replacing(/\*([^*\s][^*]*)\*/) { m in "<i>\(m.1)</i>" }

        let paragraphs = s.components(separatedBy: "\n\n").map {
            $0.hasPrefix("\u{E002}") ? $0 : "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }
        var html = paragraphs.joined()
        for (i, block) in blocks.enumerated() {
            html = html.replacingOccurrences(of: "\u{E002}\(i)\u{E003}", with: block)
        }
        for (i, piece) in math.enumerated() {
            html = html.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: piece)
        }
        return html
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct MathWebView: UIViewRepresentable {
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
        // Taps flip the card, so let them through
        view.isUserInteractionEnabled = false
        view.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        context.coordinator.loaded = html
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        var loaded = ""

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let h = (message.body as? NSNumber)?.doubleValue, h > 0 else { return }
            if abs(height.wrappedValue - h) > 0.5 { height.wrappedValue = CGFloat(h) }
        }
    }
}

/// Quick TeX -> readable text for one-line labels (lists, tiles, accessibility): \mathrm{m/s^2} -> m/s²
enum TeXPlain {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "-": "⁻", "+": "⁺", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
    ]

    /// Unicode subscript when every character has one, else keep an underscore
    private static func sub(_ s: Substring) -> String {
        s.allSatisfy({ subscripts[$0] != nil }) ? String(s.map { subscripts[$0]! }) : "_" + s
    }
    // Longest first so \Delta isn't eaten by a shorter prefix
    private static let symbols: [(String, String)] = [
        ("\\varepsilon", "ε"), ("\\epsilon", "ε"), ("\\lambda", "λ"), ("\\Lambda", "Λ"), ("\\Delta", "Δ"), ("\\delta", "δ"),
        ("\\Theta", "Θ"), ("\\theta", "θ"), ("\\omega", "ω"), ("\\Omega", "Ω"), ("\\kappa", "κ"), ("\\gamma", "γ"),
        ("\\sigma", "σ"), ("\\alpha", "α"), ("\\beta", "β"), ("\\phi", "φ"), ("\\rho", "ρ"), ("\\tau", "τ"), ("\\mu", "μ"),
        ("\\pi", "π"), ("\\hbar", "ħ"), ("\\times", "×"), ("\\div", "÷"), ("\\cdots", "⋯"), ("\\cdot", "·"), ("\\odot", "⊙"),
        ("\\propto", "∝"), ("\\approx", "≈"), ("\\geq", "≥"), ("\\leq", "≤"), ("\\top", "ᵀ"), ("\\dots", "…"),
        ("\\sum", "Σ"), ("\\prod", "Π"), ("\\infty", "∞"), ("\\sin", "sin"), ("\\cos", "cos"),
        ("\\tan", "tan"), ("\\log", "log"), ("\\max", "max"), ("\\exp", "exp"), ("\\textstyle", ""), ("\\displaystyle", ""),
        ("\\left", ""), ("\\right", ""), ("\\!", ""), ("\\,", " "), ("\\;", " "), ("\\ ", " "),
        // Short names last, after the longer ones they prefix (\left, \neq, \infty, \top…)
        ("\\Rightarrow", "⇒"), ("\\forall", "∀"), ("\\square", "□"), ("\\min", "min"), ("\\neq", "≠"), ("\\ne", "≠"),
        ("\\ge", "≥"), ("\\le", "≤"), ("\\ll", "≪"), ("\\gg", "≫"), ("\\to", "→"), ("\\in", "∈"),
    ]

    static func convert(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "$$", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacing(/\*([^*\s][^*]*)\*/) { String($0.1) }
        // Inner-most groups first, a few passes for nesting
        for _ in 0..<4 {
            s = s.replacing(/\\(?:mathrm|text|operatorname|mathbf)\{([^{}]*)\}/) { String($0.1) }
            s = s.replacing(/\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}/) { "\($0.1)/\($0.2)" }
            s = s.replacing(/\\sqrt\{([^{}]*)\}/) { "√(\($0.1))" }
            s = s.replacing(/\^\{([^{}]*)\}/) { m in
                let inner = String(m.1)
                return inner.allSatisfy({ superscripts[$0] != nil }) ? String(inner.map { superscripts[$0]! }) : "^(\(inner))"
            }
            s = s.replacing(/_\{([^{}]*)\}/) { sub($0.1) }
        }
        for (tex, plain) in symbols { s = s.replacingOccurrences(of: tex, with: plain) }
        s = s.replacing(/\^([0-9nTi])/) { String(superscripts[Character(String($0.1))]!) }
        s = s.replacing(/_([0-9A-Za-z])/) { sub($0.1) }
        return s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\", with: "")
    }
}
