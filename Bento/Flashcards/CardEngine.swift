import SwiftUI
import WebKit

/// Renders and grades every interactive card kind in one web view (KaTeX for all text).
/// Kinds: choice (incl. two-way swipes), cloze, match, sort, order, grid, flaw, tag.
/// Grading happens here, on the phone; the result comes back through `onResult`.
struct CardEngine: UIViewRepresentable {
    /// The card's JSON
    let payload: String
    /// Show the solved card (Learn mode, browsing) instead of asking
    var reveal = false
    @Binding var height: CGFloat
    var onResult: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "card")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.page, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "card")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CardEngine
        private var loaded = false
        private var shown = ""

        init(_ parent: CardEngine) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            shown = ""
            push(webView)
        }

        func push(_ webView: WKWebView) {
            let key = parent.payload + (parent.reveal ? "#r" : "")
            guard loaded, key != shown else { return }
            shown = key
            webView.evaluateJavaScript("show(\(parent.payload), \(parent.reveal))")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "height":
                if let h = (body["value"] as? NSNumber)?.doubleValue, abs(parent.height - h) > 0.5 {
                    parent.height = CGFloat(h)
                }
            case "result":
                parent.onResult(body["correct"] as? Bool ?? false)
            default:
                break
            }
        }
    }

    // MARK: - Page

    static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
    <style>
    :root { color-scheme: light dark; --ink: #111; --card: #fff; --muted: #8a8a8a; --ok: #22ad54; --bad: #ff3b30; --sel: #2f7bf6; }
    @media (prefers-color-scheme: dark) { :root { --ink: #f2f2f2; --card: #1c1c1e; } }
    html, body { margin: 0; background: transparent; -webkit-user-select: none; -webkit-touch-callout: none; }
    body { font: 17px/1.4 ui-rounded, -apple-system, "Apple Color Emoji"; color: var(--ink); padding: 2px 4px 8px; display: flow-root; }
    .prompt { font-weight: 700; font-size: 20px; margin: 0 0 14px; }
    .hint { color: var(--muted); font-size: 13px; margin: -6px 0 12px; }
    .chip, .opt, .line, .bucket, .cell.blank, .slot {
      background: var(--card); border: 1.4px solid var(--ink); border-radius: 12px; box-shadow: 2px 2px 0 var(--ink); }
    .opt { padding: 13px 14px; margin: 0 0 10px; }
    .pair { display: flex; gap: 10px; } .pair .opt { flex: 1; text-align: center; font-weight: 700; }
    .chips { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0; }
    .chip { padding: 7px 11px; }
    .chip.used { opacity: .25; }
    .sel { outline: 3px solid var(--sel); outline-offset: 1px; }
    .ok { background: rgba(34,173,84,.16) !important; border-color: var(--ok) !important; }
    .bad { background: rgba(255,59,48,.12) !important; border-color: var(--bad) !important; }
    .slot { display: inline-block; min-width: 44px; padding: 1px 8px; margin: 0 2px; text-align: center; border-radius: 8px; box-shadow: none; }
    .slot.empty { color: transparent; }
    .cloze { font-size: 18px; line-height: 2.1; margin-bottom: 8px; }
    .cols { display: flex; gap: 10px; } .cols > div { flex: 1; display: flex; flex-direction: column; gap: 8px; }
    .cols .chip { min-height: 22px; }
    .tagn { display: inline-block; font-size: 11px; font-weight: 800; border-radius: 6px; padding: 0 5px; margin-right: 6px;
            background: var(--ink); color: var(--card); }
    .buckets { display: flex; gap: 10px; margin-bottom: 8px; }
    .bucket { flex: 1; padding: 8px; min-height: 64px; }
    .bucket h4 { margin: 0 0 6px; font-size: 13px; }
    .bucket .chips { margin: 0; }
    .line { padding: 10px 12px; margin: 0 0 8px; font-size: 15px; }
    .line .role { display: block; margin-top: 6px; font-size: 12px; font-weight: 700; color: var(--sel); }
    .line .role:empty { display: none; }
    table { border-collapse: separate; border-spacing: 5px; width: 100%; font-size: 13px; table-layout: fixed; }
    th { text-align: left; font-size: 12px; }
    tr > th:first-child { width: 19%; }
    /* KaTeX may break inline math after relations ("b ≤ / i ≤ n"); in narrow cells keep each formula whole */
    td .katex { white-space: nowrap; font-size: 1.05em; }
    td { vertical-align: top; padding: 6px; }
    .cell.blank { min-height: 26px; }
    .cell.blank.empty::after { content: "tap to fill"; color: var(--muted); font-size: 12px; }
    .check { margin-top: 8px; width: 100%; padding: 13px; font: 700 17px ui-rounded, -apple-system, "Apple Color Emoji"; color: var(--card);
             background: var(--ink); border: 1.5px solid var(--ink); border-radius: 14px; box-shadow: 3px 3px 0 var(--ink); }
    .check:disabled { opacity: .3; }
    .why { margin-top: 14px; padding: 12px 14px; border-radius: 14px; background: rgba(127,127,127,.12); font-size: 15px; }
    .verdict { font-weight: 800; margin-bottom: 4px; }
    .ord { display: flex; flex-direction: column; gap: 8px; margin-bottom: 8px; }
    .ord .chip .num { font-weight: 800; margin-right: 6px; }
    /* Same look as flip cards (MathText): small grey monospace pill, math a touch over text size */
    code { font-family: ui-monospace, Menlo, monospace; font-size: .86em; font-weight: 500; background: rgba(127,127,127,.15);
           padding: 1px 5px; border-radius: 5px; -webkit-box-decoration-break: clone; }
    .prompt code { font-weight: 600; }
    .katex { font-size: 1.08em; }
    /* ```fenced``` code: its own tinted box, line breaks and indents kept, scrolls sideways if long */
    pre { margin: 8px 0; padding: 10px 12px; background: rgba(127,127,127,.12); border-radius: 10px; overflow-x: auto; }
    pre code, .prompt pre code { background: none; padding: 0; font-size: .8em; font-weight: 500; line-height: 1.5; white-space: pre; }
    </style></head><body><div id="root"></div>
    <script>
    var C = null, S = {}, done = false, revealMode = false;
    function post(m) { window.webkit.messageHandlers.card.postMessage(m); }
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
    // Markdown-lite (**bold**, `code`) around TeX; math is rendered afterwards by auto-render
    function rich(s) {
      // ```fenced``` blocks come out first so $ and * inside them stay literal
      var blocks = [];
      s = String(s).replace(/\n*```[^\n]*\n([\s\S]*?)\n?```\n*/g, function (_, code) {
        blocks.push(code); return "\uE002" + (blocks.length - 1) + "\uE003";
      });
      var parts = String(s).split(/(\$\$[\s\S]+?\$\$|\$[^$\n]+?\$)/);
      return parts.map(function (p, i) {
        if (i % 2) return esc(p);
        return esc(p).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/\*([^*\s][^*]*)\*/g, "<i>$1</i>").replace(/\n/g, "<br>");
      }).join("").replace(/\uE002(\d+)\uE003/g, function (_, i) { return "<pre><code>" + esc(blocks[+i]) + "</code></pre>"; });
    }
    // Code reads as code, not a wall of Courier: spaces don't break, so a snippet only wraps
    // after "; " or ", " (statement / argument), or after "(" and "." when it has to
    function codeBreaks(el) {
      el.querySelectorAll(":not(pre) > code").forEach(function (c) {
        c.innerHTML = c.textContent.split(/(?<=[;,]) /).map(function (seg) {
          return seg.split(/(?<=[(.])/).map(function (p) { return esc(p).replace(/ /g, "&nbsp;"); }).join("<wbr>");
        }).join(" ");
      });
    }
    function math(el) {
      codeBreaks(el);
      try { renderMathInElement(el, { delimiters: [{left: "$$", right: "$$", display: true}, {left: "$", right: "$", display: false}], throwOnError: false }); } catch (e) {}
      // Shrink wide display equations to fit (down to 60%), then scroll
      el.querySelectorAll(".katex-display").forEach(function (d) {
        d.style.overflowX = "auto";
        var k = d.querySelector(".katex"); if (!k) return;
        var ratio = d.clientWidth / k.scrollWidth;
        if (ratio < 1) k.style.fontSize = Math.max(0.6, ratio * 0.94) * 1.08 + "em";
      });
    }
    function measure() { post({ type: "height", value: Math.ceil(document.body.getBoundingClientRect().height) }); }
    function shuffle(a) { a = a.slice(); for (var i = a.length - 1; i > 0; i--) { var j = Math.floor(Math.random() * (i + 1)); var t = a[i]; a[i] = a[j]; a[j] = t; } return a; }
    function h(tag, cls, html, act) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; if (act) e.dataset.act = act; return e; }

    function finish(correct) {
      done = true;
      render();  // again, now that done is set, so the picks show green / red
      if (!revealMode) post({ type: "result", correct: correct });
      var w = h("div", "why");
      w.innerHTML = (revealMode ? "" : "<div class='verdict'>" + (correct ? "✓ Got it" : "✗ Not quite") + "</div>") + rich(C.why || "");
      if (C.why || !revealMode) document.getElementById("root").appendChild(w);
      math(w); measure();
    }
    function checkButton(enabled, label) {
      var b = h("button", "check", label || "Check", "check");
      b.disabled = !enabled;
      return b;
    }

    // ---------- Kinds ----------
    var K = {};

    // choice: { prompt, options[], answer, layout?: "pair" }
    K.choice = {
      init: function () { S.order = C.layout === "pair" ? C.options.map(function (_, i) { return i; }) : shuffle(C.options.map(function (_, i) { return i; })); S.picked = null; },
      draw: function (r) {
        var box = h("div", C.layout === "pair" ? "pair" : "");
        S.order.forEach(function (i) {
          var o = h("div", "opt", rich(C.options[i]), "pick:" + i);
          if (done || revealMode) { if (i === C.answer) o.classList.add("ok"); else if (i === S.picked) o.classList.add("bad"); }
          box.appendChild(o);
        });
        r.appendChild(box);
      },
      act: function (a) { if (done || a[0] !== "pick") return; S.picked = +a[1]; render(); finish(S.picked === C.answer); },
      solve: function () { S.picked = C.answer; }
    };

    // flaw: { prompt, lines[], bad } — tap the broken line
    K.flaw = {
      init: function () { S.picked = null; },
      draw: function (r) {
        r.appendChild(h("div", "hint", "Tap the line that's wrong"));
        C.lines.forEach(function (l, i) {
          var d = h("div", "line", rich(l), "pick:" + i);
          if (done || revealMode) { if (i === C.bad) d.classList.add("bad"); else if (i === S.picked) d.classList.add("sel"); }
          r.appendChild(d);
        });
      },
      act: function (a) { if (done || a[0] !== "pick") return; S.picked = +a[1]; render(); finish(S.picked === C.bad); },
      solve: function () { S.picked = C.bad; }
    };

    // cloze: { text with [[0]] [[1]]…, blanks: [{ answer, options[] }] }
    K.cloze = {
      init: function () { S.fill = C.blanks.map(function () { return null; }); S.cur = 0; S.opts = C.blanks.map(function (b) { return shuffle(b.options.indexOf(b.answer) < 0 ? b.options.concat([b.answer]) : b.options); }); },
      draw: function (r) {
        var html = rich(C.text).replace(/\[\[(\d+)\]\]/g, function (_, n) {
          n = +n; var v = S.fill[n];
          var cls = "slot" + (v == null ? " empty" : "") + (n === S.cur && !done ? " sel" : "");
          if (done) cls += v === C.blanks[n].answer ? " ok" : " bad";
          return "<span class='" + cls + "' data-act='blank:" + n + "'>" + (v == null ? "____" : rich(v)) + "</span>";
        });
        r.appendChild(h("div", "cloze", html));
        if (!done) {
          var chips = h("div", "chips");
          S.opts[S.cur].forEach(function (o, i) { chips.appendChild(h("div", "chip", rich(o), "opt:" + i)); });
          r.appendChild(chips);
          r.appendChild(checkButton(S.fill.every(function (v) { return v != null; })));
        }
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "blank") S.cur = +a[1];
        else if (a[0] === "opt") {
          S.fill[S.cur] = S.opts[S.cur][+a[1]];
          var next = S.fill.indexOf(null); if (next >= 0) S.cur = next;
        } else if (a[0] === "check") {
          render(); finish(S.fill.every(function (v, i) { return v === C.blanks[i].answer; })); return;
        }
        render();
      },
      solve: function () { S.fill = C.blanks.map(function (b) { return b.answer; }); }
    };

    // match: { pairs: [[left, right], …] } — tap a left, then a right
    K.match = {
      init: function () { S.right = shuffle(C.pairs.map(function (_, i) { return i; })); S.link = {}; S.selL = null; },
      draw: function (r) {
        r.appendChild(h("div", "hint", "Tap one on the left, then its match on the right"));
        var cols = h("div", "cols"), L = h("div"), R = h("div");
        var rev = {}; Object.keys(S.link).forEach(function (l) { rev[S.link[l]] = +l; });
        C.pairs.forEach(function (p, i) {
          var c = h("div", "chip", (S.link[i] != null ? "<span class='tagn'>" + (i + 1) + "</span>" : "") + rich(p[0]), "L:" + i);
          if (S.selL === i && !done) c.classList.add("sel");
          if (done) c.classList.add(S.link[i] === i ? "ok" : "bad");
          L.appendChild(c);
        });
        S.right.forEach(function (j) {
          var who = rev[j];
          var c = h("div", "chip", (who != null ? "<span class='tagn'>" + (who + 1) + "</span>" : "") + rich(C.pairs[j][1]), "R:" + j);
          if (done) c.classList.add(who === j ? "ok" : "bad");
          R.appendChild(c);
        });
        cols.appendChild(L); cols.appendChild(R); r.appendChild(cols);
        if (!done) r.appendChild(checkButton(Object.keys(S.link).length === C.pairs.length));
        if (done) {
          var fix = C.pairs.filter(function (_, i) { return S.link[i] !== i; });
          if (fix.length) r.appendChild(h("div", "hint", "Answers: " + fix.map(function (p) { return rich(p[0]) + " → " + rich(p[1]); }).join(" · ")));
        }
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "L") { var i = +a[1]; if (S.link[i] != null && S.selL !== i) { delete S.link[i]; } S.selL = i; }
        else if (a[0] === "R" && S.selL != null) {
          var j = +a[1];
          Object.keys(S.link).forEach(function (l) { if (S.link[l] === j) delete S.link[l]; });
          S.link[S.selL] = j; S.selL = null;
          for (var k = 0; k < C.pairs.length; k++) if (S.link[k] == null) { S.selL = k; break; }
        } else if (a[0] === "check") {
          render(); finish(C.pairs.every(function (_, i) { return S.link[i] === i; })); return;
        }
        render();
      },
      solve: function () { C.pairs.forEach(function (_, i) { S.link[i] = i; }); }
    };

    // sort: { buckets[], items: [[text, bucketIndex], …] } — tap an item, then a bucket
    K.sort = {
      init: function () { S.items = shuffle(C.items.map(function (_, i) { return i; })); S.at = {}; S.sel = null; },
      draw: function (r) {
        r.appendChild(h("div", "hint", "Tap an item, then the box it belongs in"));
        var bs = h("div", "buckets");
        C.buckets.forEach(function (b, bi) {
          var box = h("div", "bucket", "<h4>" + rich(b) + "</h4>", "B:" + bi), chips = h("div", "chips");
          S.items.forEach(function (i) {
            if (S.at[i] !== bi) return;
            var c = h("div", "chip", rich(C.items[i][0]), "I:" + i);
            if (done) c.classList.add(C.items[i][1] === bi ? "ok" : "bad");
            chips.appendChild(c);
          });
          box.appendChild(chips); bs.appendChild(box);
        });
        r.appendChild(bs);
        var pool = h("div", "chips");
        S.items.forEach(function (i) {
          if (S.at[i] != null) return;
          var c = h("div", "chip", rich(C.items[i][0]), "I:" + i);
          if (S.sel === i) c.classList.add("sel");
          pool.appendChild(c);
        });
        r.appendChild(pool);
        if (!done) r.appendChild(checkButton(Object.keys(S.at).length === C.items.length));
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "I") { var i = +a[1]; if (S.at[i] != null) { delete S.at[i]; S.sel = i; } else S.sel = (S.sel === i ? null : i); }
        else if (a[0] === "B" && S.sel != null) { S.at[S.sel] = +a[1]; S.sel = null; }
        else if (a[0] === "check") { render(); finish(C.items.every(function (it, i) { return S.at[i] === it[1]; })); return; }
        render();
      },
      solve: function () { C.items.forEach(function (it, i) { S.at[i] = it[1]; }); }
    };

    // order: { items[] (correct order), decoys?[] } — tap in order
    K.order = {
      init: function () { var all = C.items.concat(C.decoys || []); S.pool = shuffle(all.map(function (_, i) { return i; })); S.all = all; S.seq = []; },
      draw: function (r) {
        r.appendChild(h("div", "hint", "Tap them in order" + ((C.decoys || []).length ? " (some don't belong)" : "") + " · tap a numbered one to undo"));
        var ord = h("div", "ord");
        S.seq.forEach(function (i, n) {
          var c = h("div", "chip", "<span class='num'>" + (n + 1) + ".</span>" + rich(S.all[i]), "S:" + n);
          if (done) c.classList.add(i === n && n < C.items.length ? "ok" : "bad");
          ord.appendChild(c);
        });
        r.appendChild(ord);
        if (!done) {
          var pool = h("div", "chips");
          S.pool.forEach(function (i) { if (S.seq.indexOf(i) < 0) pool.appendChild(h("div", "chip", rich(S.all[i]), "P:" + i)); });
          r.appendChild(pool);
          r.appendChild(checkButton(S.seq.length >= C.items.length));
        } else if (!S.seq.every(function (i, n) { return i === n; }) || S.seq.length !== C.items.length) {
          r.appendChild(h("div", "hint", "Order: " + C.items.map(function (t, n) { return (n + 1) + ". " + rich(t); }).join("<br>")));
        }
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "P") { var i = +a[1]; if (S.seq.indexOf(i) < 0) S.seq.push(i); }
        else if (a[0] === "S") { S.seq.splice(+a[1], 1); }
        else if (a[0] === "check") { render(); finish(S.seq.length === C.items.length && S.seq.every(function (i, n) { return i === n; })); return; }
        render();
      },
      solve: function () { S.seq = C.items.map(function (_, i) { return i; }); }
    };

    // grid: { cols[], rows: [{ head, cells[] }], hidden: [[r, c], …] } — fill the blanked cells
    K.grid = {
      init: function () {
        S.fill = {}; S.cur = 0;
        S.pool = shuffle(C.hidden.map(function (rc) { return C.rows[rc[0]].cells[rc[1]]; }));
      },
      draw: function (r) {
        var t = h("table"), head = h("tr");
        head.appendChild(h("th", "", ""));
        C.cols.forEach(function (c) { head.appendChild(h("th", "", rich(c))); });
        t.appendChild(head);
        C.rows.forEach(function (row, ri) {
          var tr = h("tr"); tr.appendChild(h("th", "", rich(row.head)));
          row.cells.forEach(function (cell, ci) {
            var hi = -1; C.hidden.forEach(function (rc, k) { if (rc[0] === ri && rc[1] === ci) hi = k; });
            if (hi < 0) { tr.appendChild(h("td", "", rich(cell))); return; }
            var v = S.fill[hi] == null ? null : S.pool[S.fill[hi]];
            var td = h("td", "cell blank" + (v == null ? " empty" : "") + (hi === S.cur && !done ? " sel" : ""), v == null ? "" : rich(v), "cell:" + hi);
            if (done) td.classList.add(v === cell ? "ok" : "bad");
            if (done && v !== cell) td.innerHTML = (v == null ? "" : "<s>" + rich(v) + "</s><br>") + rich(cell);
            tr.appendChild(td);
          });
          t.appendChild(tr);
        });
        r.appendChild(t);
        if (!done) {
          var chips = h("div", "chips");
          var used = Object.keys(S.fill).map(function (k) { return S.fill[k]; });
          S.pool.forEach(function (o, i) { if (used.indexOf(i) < 0) chips.appendChild(h("div", "chip", rich(o), "opt:" + i)); });
          r.appendChild(chips);
          r.appendChild(checkButton(Object.keys(S.fill).length === C.hidden.length));
        }
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "cell") { S.cur = +a[1]; delete S.fill[S.cur]; }  // tapping a filled cell empties it
        else if (a[0] === "opt") {
          S.fill[S.cur] = +a[1];
          for (var k = 0; k < C.hidden.length; k++) if (S.fill[k] == null) { S.cur = k; break; }
        } else if (a[0] === "check") {
          render(); finish(C.hidden.every(function (rc, k) { return S.fill[k] != null && S.pool[S.fill[k]] === C.rows[rc[0]].cells[rc[1]]; })); return;
        }
        render();
      },
      solve: function () {
        var taken = [];
        C.hidden.forEach(function (rc, k) {
          var cell = C.rows[rc[0]].cells[rc[1]];
          var i = S.pool.findIndex(function (o, j) { return o === cell && taken.indexOf(j) < 0; });
          taken.push(i); S.fill[k] = i;
        });
      }
    };

    // tag: { lines[], roles[], answers[] (role index per line) } — tap a line, then its role
    K.tag = {
      init: function () { S.tags = C.lines.map(function () { return null; }); S.cur = 0; },
      draw: function (r) {
        r.appendChild(h("div", "hint", "Tap a line, then what it's doing"));
        C.lines.forEach(function (l, i) {
          var d = h("div", "line", rich(l) + "<span class='role'>" + (S.tags[i] != null ? esc(C.roles[S.tags[i]]) : "") + "</span>", "line:" + i);
          if (i === S.cur && !done) d.classList.add("sel");
          if (done) d.classList.add(S.tags[i] === C.answers[i] ? "ok" : "bad");
          if (done && S.tags[i] !== C.answers[i]) d.querySelector(".role").textContent = "→ " + C.roles[C.answers[i]];
          r.appendChild(d);
        });
        if (!done) {
          var chips = h("div", "chips");
          C.roles.forEach(function (ro, i) { chips.appendChild(h("div", "chip", esc(ro), "role:" + i)); });
          r.appendChild(chips);
          r.appendChild(checkButton(S.tags.every(function (t) { return t != null; })));
        }
      },
      act: function (a) {
        if (done) return;
        if (a[0] === "line") S.cur = +a[1];
        else if (a[0] === "role") {
          S.tags[S.cur] = +a[1];
          var next = S.tags.indexOf(null); if (next >= 0) S.cur = next;
        } else if (a[0] === "check") {
          render(); finish(S.tags.every(function (t, i) { return t === C.answers[i]; })); return;
        }
        render();
      },
      solve: function () { S.tags = C.answers.slice(); }
    };

    // ---------- Shell ----------
    function render() {
      var r = document.getElementById("root");
      r.innerHTML = "";
      if (C.prompt) r.appendChild(h("div", "prompt", rich(C.prompt)));
      K[C.kind].draw(r);
      if (revealMode) r.querySelectorAll(".hint").forEach(function (e) { e.remove(); });  // no "tap…" on a solved card
      math(r);
      measure();
    }
    function show(card, reveal) {
      C = card; S = {}; done = false; revealMode = reveal;
      if (!K[C.kind]) { document.getElementById("root").textContent = "Unknown card kind: " + C.kind; measure(); return; }
      K[C.kind].init();
      if (reveal) { K[C.kind].solve(); done = true; render(); finish(true); }
      else render();
    }

    // Taps on touchend (click is unreliable in a non-scrolling WKWebView); one gesture, one action
    var sx = 0, sy = 0, moved = false, last = 0;
    function act(t) {
      var now = Date.now(); if (now - last < 250) return; last = now;
      var el = t.closest("[data-act]"); if (!el || !C) return;
      K[C.kind].act(el.dataset.act.split(":"));
    }
    document.addEventListener("touchstart", function (e) { sx = e.touches[0].clientX; sy = e.touches[0].clientY; moved = false; }, { passive: true });
    document.addEventListener("touchmove", function (e) { if (Math.abs(e.touches[0].clientX - sx) > 8 || Math.abs(e.touches[0].clientY - sy) > 8) moved = true; }, { passive: true });
    document.addEventListener("touchend", function (e) { if (moved) return; if (e.target.closest("[data-act]")) e.preventDefault(); act(e.target); });
    document.addEventListener("click", function (e) { act(e.target); });
    if (window.ResizeObserver) new ResizeObserver(measure).observe(document.body);
    if (document.fonts) document.fonts.ready.then(measure);
    </script></body></html>
    """#
}
