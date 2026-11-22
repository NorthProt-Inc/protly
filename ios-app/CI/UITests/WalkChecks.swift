import UIKit
import XCTest

/// diag/p1-walk-back (P1a follow-up): does walking the cursor back read the whole field before the cursor, and how is
/// the start found? On this branch every read is FieldText.walkRead: a selection is collapsed first; from there the
/// unit walk back (one unit a step) and one move forward again, then the walk forward to the end; then from the end
/// the jump walk back (by the before-context) and jump1 (by it less one unit), each followed by one move forward and a
/// walk to the end again. The CI stub answers with the shape and hash of what the read returned, then the numbers:
/// `read <utf16> <lf> <tokens> h<hash> | u=<units>/<lf>/h<hash>/<reason>/<return>/<ms>ms f=... j=... fj=... j1=...`.
/// The test hashes the host's text the same way (FieldText.fnv) and says which walked texts match it. Lengths,
/// line-feed counts, hashes and timings only, never text. The keyboard logs every step (keyboard-log.txt, category
/// `read`: `walk`, `wb`, `wr`, `wf` lines); each try is a MARK line in ui-log.txt.
enum WalkProbe {
    struct Case {
        let name: String
        /// The host's `rfill-<fill>` button: HostApp.swift ReadDrafts.all, 1-based (p5 3, p5mid 4, l5 5, longmid 7,
        /// xlong 8, l5mid 13, trail 14).
        let fill: Int
        let tries: Int
        var selectAll = false
    }

    static let uikit: [Case] = [
        Case(name: "p5", fill: 3, tries: 2), Case(name: "l5", fill: 5, tries: 2), Case(name: "xlong", fill: 8, tries: 2),
        Case(name: "p5mid", fill: 4, tries: 2), Case(name: "l5mid", fill: 13, tries: 1),
        Case(name: "longmid", fill: 7, tries: 1), Case(name: "trail", fill: 14, tries: 1),
        // The keyboard collapses the selection with +1, -1 and 0 in turn (FieldText.selCalls).
        Case(name: "selp5", fill: 3, tries: 3, selectAll: true), Case(name: "selxlong", fill: 8, tries: 3, selectAll: true),
    ]
    static let swiftui: [Case] = [
        Case(name: "p5", fill: 3, tries: 2), Case(name: "l5", fill: 5, tries: 2), Case(name: "xlong", fill: 8, tries: 2),
    ]
    static let webHosts = ["textarea", "lexical"]
    static let web: [Case] = [Case(name: "p5", fill: 3, tries: 2), Case(name: "xlong", fill: 8, tries: 1)]

    static func ids(_ host: String, _ cases: [Case]) -> [String] { cases.map { "walk-\(host)-\($0.name)" } }

    /// FNV-1a (32 bit) over UTF-16 units, as FieldText.fnv and read-probe.html fnv().
    static func fnv(_ u: [UInt16]) -> String {
        var h: UInt32 = 0x811C_9DC5
        for x in u {
            h ^= UInt32(x)
            h = h &* 0x0100_0193
        }
        return String(format: "%08x", h)
    }

    static func shape(_ u: [UInt16]) -> String { "\(u.count)/\(u.filter { $0 == 10 }.count)/h\(fnv(u))" }

    static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let ns = s as NSString
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    /// The stub's reply against the host's text. `whole`: what the read returned is the field (length, line feeds,
    /// hash). `u` (the unit walk back from the cursor): `pre` = it is the field's first n units, `win` = it is the n
    /// units just before the cursor, `cur` = n is the cursor's offset. `f` (the walk forward from the cursor): `suf` =
    /// it is the field's last n units. `j`, `j1` (walks back from the end): `pre`, and `all` = n is the field's length.
    /// On the web page only `whole` (the page posts numbers, not text).
    static func judge(_ carried: String, real: [UInt16]?, realShape: String, cursor: Int?) -> String {
        var out: [String] = []
        if let g = groups(#"^read (\d+) (\d+) \S+ h([0-9a-f]{8})"#, carried) {
            out.append("whole=" + ("\(g[0])/\(g[1])/h\(g[2])" == realShape ? "1" : "0"))
        } else {
            out.append("whole=unparsed")
        }
        guard let real else { return out.joined(separator: " ") }
        func walked(_ tag: String) -> (n: Int, hash: String)? {
            guard let g = groups(#"(?:^| )"# + tag + #"=(\d+)/\d+/h([0-9a-f]{8})/"#, carried), let n = Int(g[0]),
                  n <= real.count else { return nil }
            return (n, g[1])
        }
        if let w = walked("u") {
            let pre = fnv(Array(real.prefix(w.n))) == w.hash
            var win = "-", cur = "-"
            if let cursor, cursor <= real.count, w.n <= cursor {
                win = fnv(Array(real[(cursor - w.n)..<cursor])) == w.hash ? "1" : "0"
                cur = w.n == cursor ? "1" : "0"
            } else if cursor != nil {
                cur = "0"
            }
            out.append("u=pre\(pre ? 1 : 0)/win\(win)/cur\(cur)")
        }
        if let w = walked("f") {
            out.append("f=suf" + (fnv(Array(real.suffix(w.n))) == w.hash ? "1" : "0"))
        }
        for tag in ["j", "j1"] {
            guard let w = walked(tag) else { continue }
            let pre = fnv(Array(real.prefix(w.n))) == w.hash
            out.append("\(tag)=pre\(pre ? 1 : 0)/all\(w.n == real.count ? 1 : 0)")
        }
        return out.joined(separator: " ")
    }
}

extension PhoneRun {
    // MARK: test5j_walkuikit, test5k_walkswiftui

    func checksWalkNative(_ host: String, _ cases: [WalkProbe.Case]) {
        if notReady(WalkProbe.ids(host, cases)) { return }
        for c in cases {
            let item = Item("walk-\(host)-\(c.name)")
            for t in 1...c.tries {
                let mark = "wk-" + host + "-" + c.name + "-" + String(t)
                item.note("t\(t)={" + walkTry(c, host: host, web: nil, mark: mark) + "}")
            }
            finish(item, record: true)
        }
        d.clearField()
    }

    // MARK: test5l_walkweb

    func checksWalkWeb() {
        let ids = WalkProbe.webHosts.flatMap { WalkProbe.ids($0, WalkProbe.web) }
        if notReady(ids) { return }
        // Row 1 on the solid host: on the web screen the form accessory bar sits above the keyboard (TypingChecks).
        guard let row1 = d.rowOne() else {
            for id in ids { write(id, "FAIL", "unreadable: no row 1 on the host before the web screen") }
            return
        }
        d.app.terminate()
        d.launch(arguments: ["-screen", "readweb"])
        d.fixedRow1 = row1
        defer { d.fixedRow1 = nil }
        let web = ReadWeb(d: d)
        guard web.waitLoaded() else {
            for id in ids { write(id, "FAIL", "unreadable: the read-probe page did not load") }
            return
        }
        for host in WalkProbe.webHosts {
            for c in WalkProbe.web {
                let item = Item("walk-\(host)-\(c.name)")
                for t in 1...c.tries {
                    let mark = "wk-" + host + "-" + c.name + "-" + String(t)
                    item.note("t\(t)={" + walkTry(c, host: host, web: web, mark: mark) + "}")
                }
                finish(item, record: true)
            }
        }
    }

    /// The page's numbers for one field: `len/lf/h<hash>`.
    private func webShape(_ web: ReadWeb, _ host: String) -> String {
        guard let s = web.state()?[host] as? [String: Any] else { return "unreadable" }
        let len = (s["len"] as? NSNumber)?.intValue ?? -1
        let lf = (s["lf"] as? NSNumber)?.intValue ?? -1
        return "\(len)/\(lf)/h\(s["h"] as? String ?? "?")"
    }

    /// One call: fill (and select all, or on the web page Dismiss and a tap at the field's end), the protly key, the
    /// stub's reply judged against the host's text, Cancel, and the field left as it was.
    private func walkTry(_ c: WalkProbe.Case, host: String, web: ReadWeb?, mark: String) -> String {
        let fill = d.app.buttons["rfill-\(c.fill)"]
        if let web {
            web.clear()
            guard web.focus(host) else { return "nofocus" }
            guard protlyUp() else { return "noprotly" }
            guard fill.waitForExistence(timeout: 3) else { return "nobutton" }
            fill.tap()
            d.pause(0.8)
            // The page's own fill is unseen by the proxy (runs 7e031fc-122, 3c208a9-124); Dismiss, then a tap at the
            // field's end makes the page send its state (run 28771e2-127: the last 2 sentences).
            let dismiss = d.app.buttons["dismiss"]
            guard dismiss.waitForExistence(timeout: 3) else { return "nodismiss" }
            dismiss.tap()
            d.pause(1.0)
            guard web.focusEnd(host) else { return "nofocusend" }
            guard protlyUp() else { return "noprotly-refocus" }
            d.pause(0.5)
        } else {
            d.clearField()
            guard fill.waitForExistence(timeout: 3) else { return "nobutton" }
            fill.tap()
            d.pause(0.8)
            if c.selectAll {
                let b = d.app.buttons["rselall"]
                guard b.waitForExistence(timeout: 3) else { return "noselall" }
                b.tap()
                d.pause(0.8)
            }
        }
        var real: [UInt16]?
        var realShape = "unreadable"
        var cursor: Int?
        var sel = "-"
        if let web {
            realShape = webShape(web, host)
        } else if let text = field() {
            let u = Array(text.utf16)
            real = u
            realShape = WalkProbe.shape(u)
            if host == "uikit" {
                sel = d.probeValue("sel") ?? "?"
                let parts = sel.split(separator: ",").compactMap { Int($0) }
                if parts.count == 2, parts[1] == 0 { cursor = parts[0] }
            } else {
                cursor = u.count  // a SwiftUI TextField fill leaves the cursor at the end
            }
        }
        d.mark(mark)
        let t0 = Date()
        d.tapKey(.protlyKey)
        // The walk can take minutes (FieldText: the first long unit walk may run 200 s): poll the tree sparingly.
        let r = poll(300, every: 1.5) { v in v.strip.isEmpty && (!v.card.isEmpty || !v.panel.isEmpty) }
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        guard let v = r.view, r.met else {
            return "real=\(realShape) sel=\(sel) outcome=timeout s=\(secs) strip=\(q(r.view?.stripText))"
        }
        let onPanel = !v.panel.isEmpty
        let carried = onPanel ? v.texts(v.panel).map(\.label).joined(separator: " ") : (v.cardRows.body.first ?? "none")
        let verdict = onPanel ? "outcome=panel" : WalkProbe.judge(carried, real: real, realShape: realShape, cursor: cursor)
        let selAfter = web == nil && host == "uikit" ? (d.probeValue("sel") ?? "?") : "-"
        if let cancel = v.button("Cancel", in: onPanel ? v.panel : v.card) {
            d.pause(0.6)  // the card ignores taps for 0.5 s after it appears
            d.point(cancel.frame.midX, cancel.frame.midY).tap()
            d.pause(0.8)
        }
        let left = web.map { webShape($0, host) } ?? (field().map { WalkProbe.shape(Array($0.utf16)) } ?? "unreadable")
        return "real=\(realShape) sel=\(sel) carried=\(q(carried)) \(verdict) s=\(secs) selafter=\(selAfter) left=\(left)"
    }
}
