import UIKit
import XCTest

/// One-pass whole-field read checks: the protly key reads the whole field, Replace swaps all of it synchronously, Undo
/// puts it back synchronously. The host's `rfill-<n>` buttons put a draft in the field (HostApp.swift WholeDrafts) that
/// starts with the CI stub's `read` marker line, so the stub answers `read <utf16>/<lf>/h<fnv>` (StubActionClient).
/// Pass rules: accepted reads exact by hash; refusals within the cap with the cursor back; field exact after Replace
/// and Undo by this test's own read; keys-wait < 100 ms and short-case `read ms` <= 2500 (checks.py `resolve_whole_log`).
/// Lengths, line-feed counts, hashes, offsets and timings only, never text.
enum WholeChecks {
    /// The same lists as checks.py WHOLE_NATIVE_CASES, WHOLE_WEB_CASES and WHOLE_WEB_HOSTS (test_checks.py compares).
    static let nativeCases = ["win", "mid", "sel", "swin", "smid", "ssel", "emoji", "x14k", "cancel"]
    static let webCases = ["win", "swin", "emoji"]
    static let webHosts = ["textarea"]
    /// Tries per case, all of which must pass; 1 for the others (checks.py WHOLE_TRIES).
    static let tries: [String: Int] = ["win": 2, "swin": 3, "smid": 2, "ssel": 2]

    /// The same lists as checks.py WHOLE_NATIVE_IDS and WHOLE_WEB_IDS.
    static var nativeIDs: [String] {
        nativeCases.map { "wr-uikit-\($0)" } + nativeCases.map { "wr-swiftui-\($0)" }
    }

    static var webIDs: [String] { webHosts.flatMap { h in webCases.map { "wr-\(h)-\($0)" } } }

    /// KeyboardViewController.refusedText.
    static let refusal = "Could not read the whole text. Copy it, then use Read clipboard."
    /// ProgressStrip's second line once a read runs past 2 s.
    static let progress = "Reading the whole text\u{2026}"
    /// Replace and Undo are synchronous; the host applies the deletes and insert within this timeout.
    static let writeTimeout: TimeInterval = 15
    /// One-pass read cap (6 s) plus the stub's call (~0.5 s) and UI polling margin.
    static let readTimeout: TimeInterval = 15

    struct Spec {
        let name: String
        /// HostApp.swift WholeDrafts.all, 1-based (`rfill-<fill>`).
        let fill: Int
        /// The draft's UTF-16 length with the marker line (HostApp.swift WholeDrafts.all).
        let units: Int
        /// The cursor's UTF-16 offset before the protly key (the end, or inside paragraph 2).
        let cursor: Int
        var selectAll = false
        /// The keyboard must refuse (too long for the time cap, or text with emoji on a web host).
        var refusal = false
        /// A refusal on web hosts only: native hosts move by UTF-16 units and read it.
        var nativeReads = false
        /// Cancel on the strip once it says the read is still going: the caret goes back, the field stays.
        var cancel = false
    }

    static func spec(_ name: String) -> Spec? {
        switch name {
        case "win": return Spec(name: name, fill: 1, units: 335, cursor: 335)
        case "mid": return Spec(name: name, fill: 2, units: 335, cursor: 112)
        case "sel": return Spec(name: name, fill: 1, units: 335, cursor: 335, selectAll: true)
        case "x14k": return Spec(name: name, fill: 3, units: 14055, cursor: 14055, refusal: true)
        case "emoji": return Spec(name: name, fill: 4, units: 460, cursor: 460, refusal: true, nativeReads: true)
        case "cancel": return Spec(name: name, fill: 2, units: 335, cursor: 112, cancel: true)
        case "swin": return Spec(name: name, fill: 5, units: 39, cursor: 39)
        case "smid": return Spec(name: name, fill: 6, units: 39, cursor: 26)
        case "ssel": return Spec(name: name, fill: 5, units: 39, cursor: 39, selectAll: true)
        default: return nil
        }
    }

    /// The SwiftUI field's selection (HostApp.swift SelectingField) needs iOS 18.
    static var hasTextSelection: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// UTF-16 length, line-feed count and FNV-1a hash of a text.
    struct Shape: Equatable {
        let len: Int
        let lf: Int
        let h: String

        init(len: Int, lf: Int, h: String) {
            self.len = len
            self.lf = lf
            self.h = h
        }

        init(_ u: [UInt16]) {
            self.init(len: u.count, lf: u.filter { $0 == 10 }.count, h: WholeChecks.fnv(u))
        }

        var text: String { "\(len)/\(lf)/h\(h)" }
    }

    /// FNV-1a (32 bit) over UTF-16 units, 8 hex digits, as ProtlyCore WholeRead.fnv and read-probe.html fnv().
    static func fnv(_ u: [UInt16]) -> String {
        var h: UInt32 = 0x811C_9DC5
        for x in u {
            h ^= UInt32(x)
            h = h &* 0x0100_0193
        }
        return String(format: "%08x", h)
    }

    /// The stub's reply: the shape it carried; nil when it is not one.
    static func parseReply(_ s: String) -> Shape? {
        guard let re = try? NSRegularExpression(pattern: #"^read (\d+)/(\d+)/h([0-9a-f]{8})$"#),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        let g = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        guard let len = Int(g[0]), let lf = Int(g[1]) else { return nil }
        return Shape(len: len, lf: lf, h: g[2])
    }
}

/// The host's read page (`-screen readweb`, read-probe.html): the textarea's shape and caret from `web-state`.
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

    func shape(_ field: String) -> WholeChecks.Shape? {
        guard let s = state()?[field] as? [String: Any], let len = (s["len"] as? NSNumber)?.intValue,
              let lf = (s["lf"] as? NSNumber)?.intValue, let h = s["h"] as? String else { return nil }
        return WholeChecks.Shape(len: len, lf: lf, h: h)
    }

    func caret(_ field: String) -> String? {
        guard let s = state()?[field] as? [String: Any], let c = s["caret"] as? [NSNumber], c.count == 2 else { return nil }
        return "\(c[0].intValue),\(c[1].intValue - c[0].intValue)"
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
            if shape("textarea") != nil, rect("textarea") != nil { return true }
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

    func focusEnd(_ field: String) -> Bool {
        guard let r = rect(field) else { return false }
        d.point(r.maxX - 6, r.maxY - 6).tap()
        d.pause(0.5)
        return true
    }

    func clear() {
        let button = d.app.buttons["clear"]
        guard button.waitForExistence(timeout: 2) else {
            d.fail("clear button not found")
            return
        }
        button.tap()
        d.pause(0.5)
        for name in WholeChecks.webHosts where shape(name)?.len != 0 {
            d.fail("Clear did not empty the \(name) field (\(shape(name)?.text ?? "unreadable"))")
        }
    }
}

extension PhoneRun {
    // MARK: test5g_wholenative

    /// The UITextView screen (PhoneRun launched it with `-wholefills 1`), then the SwiftUI field of the default screen.
    func checksWholeNative() {
        if notReady(WholeChecks.nativeIDs) { return }
        for name in WholeChecks.nativeCases { wholeCase("uikit", name, web: nil) }
        d.clearField()
        d.app.terminate()
        d.launch(arguments: ["-wholefills", "1"])
        guard d.ensureProtly() else {
            for name in WholeChecks.nativeCases {
                unreadableLine("wr-swiftui-\(name)", "protly keyboard not up on the SwiftUI screen")
            }
            return
        }
        for name in WholeChecks.nativeCases { wholeCase("swiftui", name, web: nil) }
        d.clearField()
    }

    // MARK: test5h_wholeweb

    /// The read page's textarea.
    func checksWholeWeb() {
        let ids = WholeChecks.webIDs
        if notReady(ids) { return }
        guard let row1 = d.rowOne() else {
            for id in ids { unreadableLine(id, "no row 1 on the host before the web screen") }
            return
        }
        d.app.terminate()
        d.launch(arguments: ["-screen", "readweb"])
        d.fixedRow1 = row1
        defer { d.fixedRow1 = nil }
        let web = ReadWeb(d: d)
        guard web.waitLoaded() else {
            for id in ids { unreadableLine(id, "the read page did not load (state \(q(d.probeValue("web-state"))))") }
            return
        }
        for host in WholeChecks.webHosts {
            for name in WholeChecks.webCases { wholeCase(host, name, web: web) }
        }
        web.clear()
    }

    // MARK: One case

    private struct WholeTry {
        var parts: [String] = []
        var failures: [String] = []
        var unreadable: String?

        mutating func add(_ s: String) { parts.append(s) }

        mutating func check(_ ok: Bool, _ s: String) {
            parts.append(s)
            if !ok { failures.append(s) }
        }
    }

    /// One line per case: PASS only when every try passed.
    private func wholeCase(_ host: String, _ name: String, web: ReadWeb?) {
        let id = "wr-\(host)-\(name)"
        guard let spec = WholeChecks.spec(name) else {
            unreadableLine(id, "no case \(name)")
            return
        }
        let item = Item(id)
        for t in 1...(WholeChecks.tries[name] ?? 1) {
            let r = wholeTry(spec, host: host, web: web, mark: "\(id)-t\(t)")
            item.note("t\(t)={" + r.parts.joined(separator: " ") + "}")
            if let why = r.unreadable { item.markUnreadable("t\(t): \(why)") }
            if !r.failures.isEmpty { item.require("t\(t)", false, r.failures.joined(separator: " ")) }
        }
        finish(item)
    }

    /// Fill, cursor or selection, protly key, reply against field, Replace (UI read), Undo (UI read); or refusal / cancel.
    private func wholeTry(_ s: WholeChecks.Spec, host: String, web: ReadWeb?, mark: String) -> WholeTry {
        var r = WholeTry()
        if let why = wholeSetUp(s, host: host, web: web) {
            r.unreadable = "set-up: \(why)"
            return r
        }
        let original: [UInt16]? = web == nil ? field().map { Array($0.utf16) } : nil
        let found: WholeChecks.Shape? = web.map { $0.shape(host) } ?? original.map { WholeChecks.Shape($0) }
        guard let before = found else {
            r.unreadable = "the field is unreadable before the protly key"
            return r
        }
        r.add("real=\(before.text)")
        guard before.len == s.units else {
            r.unreadable = "the fill gave \(before.len) units, want \(s.units)"
            return r
        }
        let want = s.selectAll ? "0,\(s.units)" : "\(s.cursor),0"
        let caretBefore = wholeCaret(host, web)
        r.add("caret=\(caretBefore ?? "unreadable")")
        guard caretBefore == want else {
            r.unreadable = "the caret is \(caretBefore ?? "unreadable"), want \(want)"
            return r
        }

        d.mark(mark)
        let t0 = Date()
        d.tapKey(.protlyKey)
        if s.cancel { return wholeCancel(r, since: t0, before: before, caretBefore: caretBefore, host: host, web: web) }
        let p = poll(WholeChecks.readTimeout, every: 1.0) { v in
            !v.panel.isEmpty || v.finished("Replace")
                || (v.strip.isEmpty && !v.card.isEmpty && v.button("Replace", in: v.card) == nil)
        }
        r.add(String(format: "s=%.1f", Date().timeIntervalSince(t0)))
        guard var v = p.view, p.met else {
            r.check(false, "outcome=timeout strip=\(q(p.view?.stripText))")
            closeCall(p.view)
            return r
        }

        if s.refusal, web != nil || !s.nativeReads {
            if v.panel.isEmpty {
                let reply = v.texts(v.card).map(\.label).first { $0.hasPrefix("read ") }
                r.check(false, "outcome=card reply=\(reply.flatMap { WholeChecks.parseReply($0)?.text } ?? "none")")
            } else {
                let msg = v.texts(v.panel).map(\.label).joined(separator: " ")
                r.check(msg == WholeChecks.refusal, "panel=\(q(msg))")
            }
            closeCall(v)
            let left = wholeShape(host, web)
            r.check(left == before, "left=\(left?.text ?? "unreadable")")
            let c = wholeCaret(host, web)
            r.check(c == caretBefore, "caret-left=\(c ?? "unreadable") want \(caretBefore ?? "unreadable")")
            return r
        }

        guard v.panel.isEmpty else {
            r.check(false, "outcome=panel msg=\(q(v.texts(v.panel).map(\.label).joined(separator: " ")))")
            closeCall(v)
            return r
        }
        if !v.texts(v.card).contains(where: { $0.label.hasPrefix("read ") }) {
            let again = poll(5, every: 0.5) { w in w.texts(w.card).contains { $0.label.hasPrefix("read ") } }
            if let w = again.view, again.met { v = w }
        }
        let texts = v.texts(v.card).map(\.label)
        guard let reply = texts.first(where: { $0.hasPrefix("read ") }), let parsed = WholeChecks.parseReply(reply) else {
            r.check(false, "reply=unparsed card-labels=\(texts.count) units=\(texts.map { $0.utf16.count }.reduce(0, +))")
            closeCall(v)
            return r
        }
        r.check(parsed == before, "reply=\(parsed.text)")
        r.add("caret-read=\(wholeCaret(host, web) ?? "unreadable")")
        guard let replace = v.button("Replace", in: v.card), replace.enabled else {
            r.check(false, "replace=none buttons=\(q(v.buttons(v.card)))")
            closeCall(v)
            return r
        }

        let target = Array(reply.utf16)
        d.pause(0.6)  // the card ignores taps for 0.5 s after it appears
        let t1 = Date()
        d.point(replace.frame.midX, replace.frame.midY).tap()
        if let secs = waitField(host, web, since: t1, timeout: WholeChecks.writeTimeout, exact: target,
                                shape: WholeChecks.Shape(target)) {
            r.add(String(format: "replace=%.2f", secs))
        } else {
            r.check(false, "replace=timeout field=\(wholeShape(host, web)?.text ?? "unreadable")")
            closeCall(d.callView())
            return r
        }

        let fixed = d.fixedRow1
        d.fixedRow1 = fixed ?? d.rowOne()
        let t2 = Date()
        d.tapKey(.protlyKey)
        d.fixedRow1 = fixed
        if let secs = waitField(host, web, since: t2, timeout: WholeChecks.writeTimeout, exact: original, shape: before) {
            r.add(String(format: "undo=%.2f", secs))
        } else {
            r.check(false, "undo=timeout field=\(wholeShape(host, web)?.text ?? "unreadable")")
            return r
        }
        return r
    }

    /// The strip's second line after 2 s, then Cancel mid-read: the strip closes, field and caret stay unchanged.
    private func wholeCancel(_ r0: WholeTry, since t0: Date, before: WholeChecks.Shape, caretBefore: String?,
                             host: String, web: ReadWeb?) -> WholeTry {
        var r = r0
        // Wait until progressAfter (2 s) is nearly up before taking the first tree snapshot (no screenshot per poll).
        d.pause(1.8)
        let deadline = Date().addingTimeInterval(6)
        var found: CallView?
        while Date() < deadline {
            if let v = d.callView() {
                found = v
                if v.stripText.contains(WholeChecks.progress) { break }
                if v.strip.isEmpty { break }
            }
            d.pause(0.2)
        }
        guard let v = found, v.stripText.contains(WholeChecks.progress) else {
            r.check(false, "progress=none strip=\(q(found?.stripText))")
            closeCall(found)
            return r
        }
        r.add(String(format: "progress=%.1f", Date().timeIntervalSince(t0)))
        guard let cancel = v.button("Cancel", in: v.strip) else {
            r.check(false, "cancel=none strip=\(q(v.stripText))")
            return r
        }
        d.point(cancel.frame.midX, cancel.frame.midY).tap()
        r.add(String(format: "cancelled=%.1f", Date().timeIntervalSince(t0)))
        d.pause(2.0)  // a step on its way settles (at most ~1 s), then the cursor goes back
        let after = d.callView()
        r.check(after.map { $0.strip.isEmpty && $0.panel.isEmpty && $0.card.isEmpty } ?? false,
                "closed=\(after.map { "\($0.strip.count)/\($0.panel.count)/\($0.card.count)" } ?? "unreadable")")
        let left = wholeShape(host, web)
        r.check(left == before, "left=\(left?.text ?? "unreadable")")
        let c = wholeCaret(host, web)
        r.check(c == caretBefore, "caret-left=\(c ?? "unreadable") want \(caretBefore ?? "unreadable")")
        return r
    }

    private func wholeSetUp(_ s: WholeChecks.Spec, host: String, web: ReadWeb?) -> String? {
        if let web {
            web.clear()
            guard web.focus(host) else { return "no \(host) frame on the read page" }
            guard protlyUp() else { return "protly keyboard not up on the \(host) field" }
            guard tapHost("rfill-\(s.fill)") else { return "no rfill-\(s.fill) button" }
            guard tapHost("dismiss", settle: 1.0) else { return "no dismiss button" }
            guard web.focusEnd(host) else { return "no \(host) frame on the read page" }
            guard protlyUp() else { return "protly keyboard not up after the tap at the field's end" }
            d.pause(0.5)
            if s.selectAll {
                guard tapHost("rselall") else { return "no rselall button" }
            } else if web.caret(host) != "\(s.cursor),0" {
                guard tapHost("rcaret") else { return "no rcaret button" }
            }
            return nil
        }
        d.clearField()
        guard protlyUp() else { return "protly keyboard not up on the \(host) field" }
        guard tapHost("rfill-\(s.fill)") else { return "no rfill-\(s.fill) button" }
        if host == "uikit" {
            guard tapHost(s.selectAll ? "rselall" : "rsync") else { return "no rselall or rsync button" }
        } else if s.selectAll || s.cursor != s.units {
            guard WholeChecks.hasTextSelection else { return "the SwiftUI field's selection needs iOS 18" }
            if s.selectAll {
                guard tapHost("rselall") else { return "no rselall button" }
            }
        } else {
            guard tapHost("dismiss", settle: 1.0) else { return "no dismiss button" }
            guard tapHost("rfocus", settle: 1.0) else { return "no rfocus button" }
            guard protlyUp() else { return "protly keyboard not up after the refocus" }
        }
        d.pause(0.5)
        return nil
    }

    private func tapHost(_ id: String, settle: TimeInterval = 0.8) -> Bool {
        let button = d.app.buttons[id]
        guard button.waitForExistence(timeout: 3) else { return false }
        button.tap()
        d.pause(settle)
        return true
    }

    private func wholeShape(_ host: String, _ web: ReadWeb?) -> WholeChecks.Shape? {
        if let web { return web.shape(host) }
        return field().map { WholeChecks.Shape(Array($0.utf16)) }
    }

    private func wholeCaret(_ host: String, _ web: ReadWeb?) -> String? {
        if let web { return web.caret(host) }
        return d.probeValue("sel")
    }

    private func waitField(_ host: String, _ web: ReadWeb?, since: Date, timeout: TimeInterval, exact: [UInt16]?,
                           shape: WholeChecks.Shape) -> TimeInterval? {
        let end = since.addingTimeInterval(timeout)
        while true {
            let done: Bool
            if web == nil, let exact {
                done = field().map { Array($0.utf16) == exact } ?? false
            } else {
                done = wholeShape(host, web) == shape
            }
            if done { return Date().timeIntervalSince(since) }
            if Date() >= end { return nil }
            d.pause(0.2)
        }
    }

    private func closeCall(_ v: CallView?) {
        guard let v else { return }
        let button = v.button("Cancel", in: v.panel) ?? v.button("Done", in: v.panel) ?? v.button("Cancel", in: v.card)
            ?? v.button("Cancel", in: v.strip)
        guard let button else { return }
        d.pause(0.6)  // the card ignores taps for 0.5 s after it appears
        d.point(button.frame.midX, button.frame.midY).tap()
        d.pause(1.0)
    }
}
