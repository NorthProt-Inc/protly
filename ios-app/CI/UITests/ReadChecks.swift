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
    /// HostApp.swift ReadDrafts.all, in the same order (rfill-1 ... rfill-8, then the window drafts rfill-9 ...).
    static let drafts = ["p3", "p3mid", "p5", "p5mid", "l5", "long", "longmid", "xlong"]
    /// Probe 3 (test5i_readwindow): HostApp.swift ReadDrafts.window, in the same order (rfill-9 ... rfill-18).
    static let window = ["run", "lines", "w1", "w12", "l5mid", "trail", "skip", "skipend", "skipl", "en"]
    /// The window drafts on both native hosts (the SwiftUI fill leaves the cursor at the end, so l5mid is l5 there).
    static let windowBoth = ["run", "lines", "w1", "w12", "l5mid", "trail", "en"]
    /// The skip drafts, UITextView only (the cursor in the middle needs its fill).
    static let windowSkip = ["skip", "skipend", "skipl"]
    /// Select all, then the protly key: drafts index into `drafts`.
    static let selectAll: [(index: Int, name: String)] = [(2, "p5"), (5, "long"), (7, "xlong")]
    static let windowTries = 2
    /// A Korean draft typed key by key (68 units, 3 paragraphs of two sentences): the owner's case.
    static let typedKorean = "\u{C624}\u{B298} \u{D68C}\u{C758} \u{B05D}\u{B0AC}\u{C5B4}. \u{C790}\u{B8CC}\u{B294} \u{B0B4}\u{C77C} \u{BCF4}\u{B0BC}\u{AC8C}.\n\n\u{C9C8}\u{BB38} \u{C788}\u{C73C}\u{BA74} \u{B9D0}\u{D574}\u{C918}. \u{C800}\u{B141}\u{C740} \u{C77C}\u{ACF1} \u{C2DC}\u{C5D0} \u{BA39}\u{C790}.\n\n\u{C7A5}\u{C18C}\u{B294} \u{B0B4}\u{AC00} \u{C815}\u{D560}\u{AC8C}. \u{B2A6}\u{C9C0} \u{B9C8}."
    /// Typed, then read again after each resync: "none" (at once), "sync" (UITextView: the selection set again with
    /// the input delegate told), "refocus" (Dismiss, then the field takes focus again without a tap; on the web
    /// page a tap at the field's bottom-right corner).
    static let resyncTries = 2
    static func fillIndex(_ name: String) -> Int {
        if let i = drafts.firstIndex(of: name) { return i }
        return drafts.count + (window.firstIndex(of: name) ?? 0)
    }
    static var windowIDs: [String] {
        ["swiftui", "uikit"].flatMap { h in windowBoth.map { "readw-\(h)-\($0)" } }
            + windowSkip.map { "readw-uikit-\($0)" } + selectAll.map { "readw-uikit-sel\($0.name)" }
            + ["readw-swiftui-typedsync", "readw-uikit-typedsync", "readw-uikit-kotypedsync", "readw-textarea-typedsync"]
            + ["readw-textarea-fillsync", "readw-lexical-fillsync"]
    }
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

    /// A tap at the field's bottom-right corner: the caret goes to the end of the last visible line.
    func focusEnd(_ field: String) -> Bool {
        guard let r = rect(field) else { return false }
        d.point(r.maxX - 6, r.maxY - 6).tap()
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

    // MARK: test5i_readwindow (probe 3)

    /// What bounds the native before-window (punctuation, line feeds, length or words), whether the after-context
    /// also stops before a single line feed, a draft ending in a line feed, a one-unit step past an empty
    /// after-context (FieldText.skipProbe, on the pilcrow drafts), and the selection path after select all.
    func checksReadWindow() {
        let ids = ReadProbe.windowIDs
        if notReady(ids) { return }
        windowHost("swiftui", ReadProbe.windowBoth)
        typedSync("swiftui", web: nil, text: ReadProbe.typed, id: "readw-swiftui-typedsync", ways: ["none", "refocus"])
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit", "-readfills", "1"])
        guard d.ensureProtly() else {
            for id in ids where id.hasPrefix("readw-uikit-") {
                write(id, "FAIL", "unreadable: protly keyboard not up on the uikit screen")
            }
            return
        }
        windowHost("uikit", ReadProbe.windowBoth + ReadProbe.windowSkip)
        for s in ReadProbe.selectAll {
            let item = Item("readw-uikit-sel\(s.name)")
            for t in 1...ReadProbe.windowTries {
                let mark = "rdw-uikit-sel" + s.name + "-" + String(t)
                let evidence = readTry(s.index, host: "uikit", web: nil, mark: mark, selectAll: true)
                item.note("t\(t)={" + evidence + "}")
            }
            finish(item, record: true)
        }
        typedSync("uikit", web: nil, text: ReadProbe.typed, id: "readw-uikit-typedsync", ways: ["none", "sync", "refocus"])
        typedSync("uikit", web: nil, text: ReadProbe.typedKorean, id: "readw-uikit-kotypedsync",
                  ways: ["none", "sync", "refocus"], tries: 1)
        d.clearField()
        // The web textarea: typed, read at once, then after Dismiss and a tap at the field's end.
        guard let row1 = d.rowOne() else {
            for id in ["readw-textarea-typedsync", "readw-textarea-fillsync", "readw-lexical-fillsync"] {
                write(id, "FAIL", "unreadable: no row 1 on the uikit host")
            }
            return
        }
        d.app.terminate()
        d.launch(arguments: ["-screen", "readweb"])
        d.fixedRow1 = row1
        defer { d.fixedRow1 = nil }
        let web = ReadWeb(d: d)
        guard web.waitLoaded() else {
            for id in ["readw-textarea-typedsync", "readw-textarea-fillsync", "readw-lexical-fillsync"] {
                write(id, "FAIL", "unreadable: the read-probe page did not load")
            }
            return
        }
        typedSync("textarea", web: web, text: ReadProbe.typed, id: "readw-textarea-typedsync", ways: ["none", "refocus"])
        // A page's own fill (p5, rfill-3): unseen by the proxy in runs 122 and 124; does a refocus make it seen?
        for host in ["textarea", "lexical"] {
            let item = Item("readw-\(host)-fillsync")
            for t in 1...ReadProbe.windowTries {
                web.clear()
                guard web.focus(host), protlyUp() else {
                    item.note("t\(t)={nofocus}")
                    continue
                }
                let b = d.app.buttons["rfill-3"]
                guard b.waitForExistence(timeout: 3) else {
                    item.note("t\(t)={nobutton}")
                    continue
                }
                b.tap()
                d.pause(0.8)
                let first = readOnce(host, web: web, mark: "rdw-" + host + "-fillsync-none-" + String(t))
                let second = resync("refocus", host: host, web: web)
                    ?? readOnce(host, web: web, mark: "rdw-" + host + "-fillsync-refocus-" + String(t))
                item.note("t\(t)={none:" + first + " refocus:" + second + "}")
            }
            finish(item, record: true)
        }
    }

    /// Types `text` once per try, then reads it once per way, each read ended with Cancel so the text stays.
    private func typedSync(_ host: String, web: ReadWeb?, text: String, id: String, ways: [String],
                           tries: Int = ReadProbe.resyncTries) {
        let item = Item(id)
        let short = id.replacingOccurrences(of: "readw-" + host + "-", with: "")
        for t in 1...tries {
            if let web {
                web.clear()
                guard web.focus(host) else {
                    item.note("t\(t)={nofocus}")
                    continue
                }
                guard protlyUp() else {
                    item.note("t\(t)={noprotly}")
                    continue
                }
            } else {
                d.clearField()
            }
            guard d.type(text) else {
                item.note("t\(t)={nottyped}")
                continue
            }
            d.pause(0.8)
            var parts: [String] = []
            for way in ways {
                if let problem = resync(way, host: host, web: web) {
                    parts.append(way + ":" + problem)
                    continue
                }
                let mark = "rdw-" + host + "-" + short + "-" + way + "-" + String(t)
                parts.append(way + ":" + readOnce(host, web: web, mark: mark))
            }
            item.note("t\(t)={" + parts.joined(separator: " ") + "}")
        }
        finish(item, record: true)
    }

    /// One resync before a read; nil when it happened, else what went wrong.
    private func resync(_ way: String, host: String, web: ReadWeb?) -> String? {
        switch way {
        case "sync":
            let b = d.app.buttons["rsync"]
            guard b.waitForExistence(timeout: 3) else { return "nobutton" }
            b.tap()
            d.pause(0.8)
        case "refocus":
            let dismiss = d.app.buttons["dismiss"]
            guard dismiss.waitForExistence(timeout: 3) else { return "nodismiss" }
            dismiss.tap()
            d.pause(1.0)
            if let web {
                guard web.focusEnd(host) else { return "nofocus" }
            } else {
                let f = d.app.buttons["rfocus"]
                guard f.waitForExistence(timeout: 3) else { return "nofocusbutton" }
                f.tap()
                d.pause(1.0)
            }
            guard protlyUp() else { return "noprotly" }
            d.pause(0.5)
        default:
            break
        }
        return nil
    }

    /// The protly key, then Cancel on the card or the panel: what the call carried, and the field left as it was.
    private func readOnce(_ host: String, web: ReadWeb?, mark: String) -> String {
        let real = shapeNow(host, web)
        d.mark(mark)
        let t0 = Date()
        d.tapKey(.protlyKey)
        let r = poll(12, every: 0.3) { v in v.strip.isEmpty && (!v.card.isEmpty || !v.panel.isEmpty) }
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        guard let v = r.view, r.met else { return "real=\(real) outcome=timeout s=\(secs)" }
        let onPanel = !v.panel.isEmpty
        let carried = onPanel ? v.texts(v.panel).map(\.label).joined(separator: " ") : (v.cardRows.body.first ?? "none")
        if let c = v.button("Cancel", in: onPanel ? v.panel : v.card) {
            d.pause(0.6)  // the card ignores taps for 0.5 s after it appears
            d.point(c.frame.midX, c.frame.midY).tap()
            d.pause(0.8)
        }
        let left = shapeNow(host, web)
        return "real=\(real) carried=\(q(carried)) outcome=\(onPanel ? "panel" : "card") s=\(secs) left=\(left)"
    }

    private func windowHost(_ host: String, _ names: [String]) {
        for name in names {
            let item = Item("readw-\(host)-\(name)")
            if host == "swiftui" && name == "l5mid" {
                item.note("cursor=end (a SwiftUI TextField fill leaves the cursor at the end)")
            }
            for t in 1...ReadProbe.windowTries {
                let mark = "rdw-" + host + "-" + name + "-" + String(t)
                let evidence = readTry(ReadProbe.fillIndex(name), host: host, web: nil, mark: mark)
                item.note("t\(t)={" + evidence + "}")
            }
            finish(item, record: true)
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
                         nudge: Bool = false, selectAll: Bool = false) -> String {
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
        if selectAll {
            // Probe 3: the host selects the whole text (UITextView, with its input delegate told), as Select All would.
            let button = d.app.buttons["rselall"]
            guard button.waitForExistence(timeout: 3) else { return "noselall" }
            button.tap()
            d.pause(0.8)
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
