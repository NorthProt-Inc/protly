import UIKit
import XCTest

/// diag/p1-phone-read (campaign 2026-11-17-keyboard-diagnosis, P1): does the whole-field read (FieldText.read) carry
/// the whole multi-line draft, and does Replace swap all of it? The host's `rfill-N` buttons put a synthetic draft in
/// the field (HostApp.swift ReadDrafts: Korean paragraphs, each starting `\u{00A7}<n> `), the protly key starts the
/// call, and on this branch the CI stub answers every draft with the shape of the text the request carried
/// ("read <utf16> <line feeds> <paragraph tokens>", StubActionClient.probe). Then Replace, and the field's shape after
/// it. Lengths, line-feed counts and paragraph tokens only, never text. The keyboard logs every read step
/// (keyboard-log.txt, category `read`); each try is a MARK line in ui-log.txt.
enum ReadProbe {
    /// HostApp.swift ReadDrafts.all, in the same order (rfill-1 ... rfill-8).
    static let drafts = ["p3", "p3mid", "p5", "p5mid", "l5", "long", "longmid", "xlong"]
    static let many: Set<String> = ["p5", "p5mid", "long"]
    static func tries(_ draft: String) -> Int { many.contains(draft) ? 10 : 3 }
    static let nativeHosts = ["swiftui", "uikit"]
    static let webHosts = ["textarea", "ce", "lexical"]
    static func ids(_ hosts: [String]) -> [String] { hosts.flatMap { h in drafts.map { "read-\(h)-\($0)" } } }

    /// test5h_readtyped: a Latin draft typed key by key (3 paragraphs, 6 sentences, 81 UTF-16 units).
    static let typed = "we met today. it went well.\n\nsee you soon. call me later.\n\nthanks again. bye now."
    static let typedTries = 2
    static let typedHosts = ["swiftui", "uikit", "textarea", "ce", "lexical"]
    /// Filled drafts with one typed key after the fill (web hosts): index into `drafts`, tries.
    static let nudged: [(index: Int, tries: Int)] = [(2, 5), (5, 5), (1, 3), (3, 3)]
    static var typedIDs: [String] {
        typedHosts.map { "readt-\($0)-typed" }
            + webHosts.flatMap { h in nudged.map { "readt-\(h)-\(drafts[$0.index])a" } }
    }
}

/// `utf16/lf/tokens`, plus `/read` when the text starts with the stub's reply.
func readShape(_ s: String) -> String {
    let lf = s.utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    let tok = (1...12).filter { s.contains("\u{00A7}\($0) ") }.map { String($0) }.joined(separator: ".")
    return "\(s.utf16.count)/\(lf)/\(tok.isEmpty ? "none" : tok)" + (s.hasPrefix("read ") ? "/read" : "")
}

/// The host's read-probe page (`-screen readweb`, read-probe.html): each field's shape from the `web-state` probe.
@MainActor
final class ReadWeb {
    let d: Driver
    private var frames: [String: CGRect] = [:]

    init(d: Driver) {
        self.d = d
    }

    func state() -> [String: Any]? {
        guard let s = d.probeValue("web-state"), let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func shape(_ field: String) -> String {
        guard let s = state()?[field] as? [String: Any] else { return "unreadable" }
        func n(_ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? -1 }
        let tok = s["tok"] as? String ?? "?"
        return "\(n("len"))/\(n("lf"))/\(tok)" + (n("read") == 1 ? "/read" : "") + "/b\(n("blocks"))"
    }

    func rect(_ field: String) -> CGRect? {
        if let r = frames[field] { return r }
        guard let s = d.probeValue("web-rects"), let data = s.data(using: .utf8),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = (all[field] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), v.count == 4,
              v[2] > 0, v[3] > 0 else { return nil }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        frames[field] = r
        return r
    }

    func waitLoaded(timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if state()?["lexical"] != nil, rect("lexical") != nil { return true }
            d.pause(0.5)
        } while Date() < end
        return false
    }

    func focus(_ field: String) -> Bool {
        guard let r = rect(field) else { return false }
        d.point(r.midX, r.midY).tap()
        d.pause(0.5)
        return true
    }

    func clear() {
        let button = d.app.buttons["clear"]
        guard button.waitForExistence(timeout: 2) else { return }
        button.tap()
        d.pause(0.5)
    }
}

extension PhoneRun {
    // MARK: test5f_readnative

    func checksReadNative() {
        let ids = ReadProbe.ids(ReadProbe.nativeHosts)
        if notReady(ids) { return }
        readHost("swiftui", web: nil)
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit", "-readfills", "1"])
        guard d.ensureProtly() else {
            for id in ReadProbe.ids(["uikit"]) { write(id, "FAIL", "unreadable: protly keyboard not up on the uikit screen") }
            return
        }
        readHost("uikit", web: nil)
        d.clearField()
    }

    // MARK: test5g_readweb

    func checksReadWeb() {
        let ids = ReadProbe.ids(ReadProbe.webHosts)
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
        for host in ReadProbe.webHosts { readHost(host, web: web) }
    }

    // MARK: test5h_readtyped

    func checksReadTyped() {
        let ids = ReadProbe.typedIDs
        if notReady(ids) { return }
        guard let row1 = d.rowOne() else {
            for id in ids { write(id, "FAIL", "unreadable: no row 1 on the host") }
            return
        }
        typedHost("swiftui", web: nil)
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit", "-readfills", "1"])
        if d.ensureProtly() {
            typedHost("uikit", web: nil)
            d.clearField()
        } else {
            write("readt-uikit-typed", "FAIL", "unreadable: protly keyboard not up on the uikit screen")
        }
        d.app.terminate()
        d.launch(arguments: ["-screen", "readweb"])
        d.fixedRow1 = row1
        defer { d.fixedRow1 = nil }
        let web = ReadWeb(d: d)
        let webIDs = ids.filter { id in ReadProbe.webHosts.contains { id.hasPrefix("readt-\($0)-") } }
        guard web.waitLoaded() else {
            for id in webIDs { write(id, "FAIL", "unreadable: the read-probe page did not load") }
            return
        }
        for host in ReadProbe.webHosts {
            typedHost(host, web: web)
            for n in ReadProbe.nudged {
                let name = ReadProbe.drafts[n.index]
                let item = Item("readt-\(host)-\(name)a")
                for t in 1...n.tries {
                    let mark = "rdt-" + host + "-" + name + "a-" + String(t)
                    let evidence = readTry(n.index, host: host, web: web, mark: mark, nudge: true)
                    item.note("t\(t)={" + evidence + "}")
                }
                finish(item, record: true)
            }
        }
    }

    private func typedHost(_ host: String, web: ReadWeb?) {
        let item = Item("readt-\(host)-typed")
        for t in 1...ReadProbe.typedTries {
            let mark = "rdt-" + host + "-typed-" + String(t)
            let evidence = readTry(0, host: host, web: web, mark: mark, typed: ReadProbe.typed)
            item.note("t\(t)={" + evidence + "}")
        }
        finish(item, record: true)
    }

    // MARK: One host

    /// Every draft on one host, each `tries` times; one RECORD line per draft with one `t<n>=` note per try.
    private func readHost(_ host: String, web: ReadWeb?) {
        for (i, name) in ReadProbe.drafts.enumerated() {
            let item = Item("read-\(host)-\(name)")
            if host == "swiftui" && name.hasSuffix("mid") {
                item.note("cursor=end (a SwiftUI TextField fill leaves the cursor at the end)")
            }
            for t in 1...ReadProbe.tries(name) {
                let mark = "rd-" + host + "-" + name + "-" + String(t)
                let evidence = readTry(i, host: host, web: web, mark: mark)
                item.note("t\(t)={" + evidence + "}")
            }
            finish(item, record: true)
        }
    }

    private func shapeNow(_ host: String, _ web: ReadWeb?) -> String {
        if let web { return web.shape(host) }
        return field().map(readShape) ?? "unreadable"
    }

    /// One call: fill, the protly key, the outcome, Replace, the field after. Returns the try's evidence.
    private func readTry(_ i: Int, host: String, web: ReadWeb?, mark: String, typed: String? = nil,
                         nudge: Bool = false) -> String {
        if let web {
            web.clear()
            guard web.focus(host) else { return "nofocus" }
            guard protlyUp() else { return "noprotly" }
        } else {
            d.clearField()
        }
        if let typed {
            // Typed on Protly key by key, as on the phone: the host builds its context from real edits.
            guard d.type(typed) else { return "nottyped" }
            d.pause(0.8)
        } else {
            let button = d.app.buttons["rfill-\(i + 1)"]
            guard button.waitForExistence(timeout: 3) else { return "nobutton" }
            button.tap()
            d.pause(0.8)
            // Run 7e031fc-122: after a JS fill the web view's proxy context stayed nil; one typed key makes the host
            // send its document state again (the key adds one character where the cursor is).
            if nudge {
                d.type("a")
                d.pause(0.8)
            }
        }
        let real = shapeNow(host, web)
        d.mark(mark)
        let t0 = Date()
        d.tapKey(.protlyKey)
        let r = poll(12, every: 0.3) { v in v.strip.isEmpty && (!v.card.isEmpty || !v.panel.isEmpty) }
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        guard let v = r.view, r.met else {
            return "real=\(real) outcome=timeout s=\(secs) strip=\(q(r.view?.stripText))"
        }
        if !v.panel.isEmpty {
            let msg = v.texts(v.panel).map(\.label).joined(separator: " ")
            if let c = v.button("Cancel", in: v.panel) {
                d.point(c.frame.midX, c.frame.midY).tap()
                d.pause(0.8)
            }
            return "real=\(real) outcome=panel s=\(secs) msg=\(q(msg))"
        }
        let carried = v.cardRows.body.first ?? "none"
        guard let replace = v.button("Replace", in: v.card), replace.enabled else {
            let buttons = v.buttons(v.card)
            if let c = v.button("Cancel", in: v.card) {
                d.pause(0.6)
                d.point(c.frame.midX, c.frame.midY).tap()
                d.pause(0.8)
            }
            return "real=\(real) carried=\(q(carried)) outcome=no-replace s=\(secs) buttons=\(q(buttons))"
        }
        d.pause(0.6)  // the card ignores taps for 0.5 s after it appears
        d.point(replace.frame.midX, replace.frame.midY).tap()
        // The deletes and the insert can take a while in a web view: wait until two readings agree.
        var after = shapeNow(host, web)
        for _ in 0..<12 {
            d.pause(0.5)
            let now = shapeNow(host, web)
            if now == after { break }
            after = now
        }
        let left = d.callView()
        var cardAfter = "none"
        if let left, !left.card.isEmpty {
            cardAfter = "open:\(left.buttons(left.card))"
            if let c = left.button("Cancel", in: left.card) {
                d.point(c.frame.midX, c.frame.midY).tap()
                d.pause(0.8)
            }
        } else {
            d.type("a")  // the bar offers Undo after Replace; a key ends it, so the protly key reads again
        }
        return "real=\(real) carried=\(q(carried)) outcome=card s=\(secs) after=\(after) card-after=\(q(cardAfter))"
    }
}
