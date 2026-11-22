import UIKit
import XCTest

/// K1b (fix/whole-field-read): the protly key reads the whole field, Replace swaps all of it, Undo puts it back. The
/// host's `rfill-<n>` buttons put a draft in the field (HostApp.swift WholeDrafts) that starts with the CI stub's
/// `read` marker line, so the stub answers with the shape of the text the request carried,
/// `read <utf16>/<lf>/h<fnv> t<read ms>` (StubActionClient). The check hashes the host's field the same way (FNV-1a
/// 32 over UTF-16 units; read-probe.html posts it for the web fields) and wants that shape, the field exactly equal to
/// the reply after Replace, the keyboard's own check of it ended with no notice, and the draft back exactly after Undo
/// (times recorded). checks.py then wants the keyboard's log to agree (`resolve_whole_log`). A refusal case wants the
/// refusal panel and the field unchanged after Cancel. Lengths, line-feed counts, hashes, offsets and timings only, never text. Each
/// try is a MARK line in ui-log.txt (`wr-<host>-<case>-t<n>`), for the keyboard's `read` log lines.
///
/// Ported from the walk-back probe (diag/p1-walk-back-strict: WalkChecks.swift, ReadChecks.swift) without its logging.
enum WholeChecks {
    /// The same lists as checks.py WHOLE_NATIVE_CASES, WHOLE_WEB_CASES and WHOLE_WEB_HOSTS (test_checks.py compares).
    static let nativeCases = ["win", "mid", "sel", "long", "x14k", "emoji", "swin", "smid", "ssel", "s3", "shead", "etail"]
    static let webCases = ["win", "mid", "sel", "long", "x14k", "emoji", "swin", "smid", "ssel", "s3", "shead"]
    static let webHosts = ["textarea", "lexical"]
    /// Tries per case, all of which must pass; 1 for the others (checks.py WHOLE_TRIES).
    static let tries: [String: Int] = ["win": 2, "long": 2]

    /// The same lists as checks.py WHOLE_NATIVE_IDS and WHOLE_WEB_IDS.
    static var nativeIDs: [String] {
        nativeCases.map { "wr-uikit-\($0)" } + ["wr-uikit-r4k", "wr-uikit-cancel"] + nativeCases.map { "wr-swiftui-\($0)" }
    }

    static var webIDs: [String] { webHosts.flatMap { h in webCases.map { "wr-\(h)-\($0)" } } }

    /// KeyboardViewController refusedText and replaceUnsureText.
    static let refusal = "Could not read the whole text. Copy it, then use Read clipboard."
    static let notice = "Replace may not have finished. Check the text."
    /// ProgressStrip's second line once a read runs past 2 s.
    static let progress = "Reading the whole text\u{2026}"
    /// Replace must leave the reply in the field, and Undo the draft, within this long after the tap; the keyboard
    /// then checks the field (its strip says "Replacing the text…" until it is done). The host applies one delete per
    /// character: run 162 took 7-12 s for 3247 units on native hosts. The times are recorded, not judged.
    static let writeTimeout: TimeInterval = 40
    /// A read takes up to 20 s (the keyboard's cap), then the stub's call about 0.5 s.
    static let readTimeout: TimeInterval = 40

    struct Spec {
        let name: String
        /// HostApp.swift WholeDrafts.all, 1-based (`rfill-<fill>`).
        let fill: Int
        /// The draft's UTF-16 length with the marker line (HostApp.swift WholeDrafts.all).
        let units: Int
        /// The cursor's UTF-16 offset before the protly key (the end, or inside paragraph 2).
        let cursor: Int
        var selectAll = false
        /// The keyboard must refuse (too long, or text with emoji on a web host).
        var refusal = false
        /// A refusal on web hosts only: native hosts move by UTF-16 units and read it (emoji: probe runs 149, 153).
        var nativeReads = false
        /// Cancel on the strip once it says the read is still going: the caret goes back, the field stays.
        var cancel = false
        /// F02c: the field's start up to its first line feed selected (`rselhead`): a partial selection, so a
        /// copy-only card of exactly the selection (the marker line), and the field unchanged.
        var head = false
    }

    /// The marker line without its line feed: what `rselhead` selects.
    static let headUnits = Array("protly-stub read".utf16)

    static func spec(_ name: String) -> Spec? {
        switch name {
        case "win": return Spec(name: name, fill: 1, units: 335, cursor: 335)
        case "mid": return Spec(name: name, fill: 2, units: 335, cursor: 112)
        case "sel": return Spec(name: name, fill: 1, units: 335, cursor: 335, selectAll: true)
        case "long": return Spec(name: name, fill: 3, units: 3247, cursor: 3247)
        case "x14k": return Spec(name: name, fill: 4, units: 14055, cursor: 14055, refusal: true)
        case "emoji": return Spec(name: name, fill: 5, units: 460, cursor: 460, refusal: true, nativeReads: true)
        case "r4k": return Spec(name: name, fill: 6, units: 3975, cursor: 3975)
        case "cancel": return Spec(name: name, fill: 2, units: 335, cursor: 112, cancel: true)
        case "swin": return Spec(name: name, fill: 7, units: 39, cursor: 39)
        case "smid": return Spec(name: name, fill: 8, units: 39, cursor: 26)
        case "ssel": return Spec(name: name, fill: 7, units: 39, cursor: 39, selectAll: true)
        case "s3": return Spec(name: name, fill: 9, units: 93, cursor: 93)
        case "shead": return Spec(name: name, fill: 7, units: 39, cursor: 39, head: true)
        case "etail": return Spec(name: name, fill: 10, units: 42, cursor: 26)
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

    /// The stub's reply: the shape it carried and the read's time in ms; nil when it is not one.
    static func parseReply(_ s: String) -> (shape: Shape, ms: Int)? {
        guard let re = try? NSRegularExpression(pattern: #"^read (\d+)/(\d+)/h([0-9a-f]{8}) t(\d+)$"#),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        let g = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        guard let len = Int(g[0]), let lf = Int(g[1]), let ms = Int(g[3]) else { return nil }
        return (Shape(len: len, lf: lf, h: g[2]), ms)
    }
}

/// The host's read page (`-screen readweb`, read-probe.html): each field's shape and caret from the `web-state` probe.
@MainActor
final class ReadWeb {
    let d: Driver
    /// The fields' frames once read: the page neither scrolls nor zooms.
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

    /// The field's selection as `location,length` (UTF-16), as the UITextView screen's `sel` probe; nil while the
    /// field has no focus.
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
            if shape("lexical") != nil, rect("lexical") != nil { return true }
            d.pause(0.5)
        } while Date() < end
        return false
    }

    /// A tap at the field's center.
    func focus(_ field: String) -> Bool {
        guard let r = rect(field) else { return false }
        d.point(r.midX, r.midY).tap()
        d.pause(0.5)
        return true
    }

    /// A tap at the field's bottom-right corner: the caret goes to the end of the last visible line (the page's fill
    /// scrolls the field to its bottom, so that is the end of the text).
    func focusEnd(_ field: String) -> Bool {
        guard let r = rect(field) else { return false }
        d.point(r.maxX - 6, r.maxY - 6).tap()
        d.pause(0.5)
        return true
    }

    /// The host's Clear: both fields empty.
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
        for name in WholeChecks.nativeCases + ["r4k", "cancel"] { wholeCase("uikit", name, web: nil) }
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

    /// The read page's textarea and Lexical-shaped field.
    func checksWholeWeb() {
        let ids = WholeChecks.webIDs
        if notReady(ids) { return }
        // Row 1 on the solid host: on the web screen the form accessory bar sits above the keyboard (TypingChecks).
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

    /// One try's readings (`parts`), what was not as expected (`failures`), or why it could not run (`unreadable`).
    private struct WholeTry {
        var parts: [String] = []
        var failures: [String] = []
        var unreadable: String?

        mutating func add(_ s: String) {
            parts.append(s)
        }

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

    /// Fill, cursor or selection, the protly key, the reply against the field, Replace (timed), Undo (timed); or, for a
    /// refusal case, the panel and Cancel. Nothing touches the field between the protly key and Replace.
    private func wholeTry(_ s: WholeChecks.Spec, host: String, web: ReadWeb?, mark: String) -> WholeTry {
        var r = WholeTry()
        if let why = wholeSetUp(s, host: host, web: web) {
            r.unreadable = "set-up: \(why)"
            return r
        }
        let original: [UInt16]? = web == nil ? field().map { Array($0.utf16) } : nil
        let found: WholeChecks.Shape?
        if let web {
            found = web.shape(host)
        } else {
            found = original.map { WholeChecks.Shape($0) }
        }
        guard let before = found else {
            r.unreadable = "the field is unreadable before the protly key"
            return r
        }
        r.add("real=\(before.text)")
        guard before.len == s.units else {
            r.unreadable = "the fill gave \(before.len) units, want \(s.units)"
            return r
        }
        let want = s.selectAll ? "0,\(s.units)" : s.head ? "0,\(WholeChecks.headUnits.count)" : "\(s.cursor),0"
        // Every host's probe must show the case's caret or selection, so a no-op set-up cannot pass as `win`.
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
        // Reads take up to 20 s: poll the tree sparingly.
        let p = poll(WholeChecks.readTimeout, every: 1.5) { v in
            !v.panel.isEmpty || v.finished("Replace")
                || (v.strip.isEmpty && !v.card.isEmpty && v.button("Replace", in: v.card) == nil)
        }
        r.add(String(format: "s=%.1f", Date().timeIntervalSince(t0)))
        guard var v = p.view, p.met else {
            r.check(false, "outcome=timeout strip=\(q(p.view?.stripText))")
            closeCall(p.view)
            return r
        }

        if s.head { return wholeHead(r, v, before: before, host: host, web: web) }
        if s.refusal, web != nil || !s.nativeReads {
            if v.panel.isEmpty {
                let reply = v.texts(v.card).map(\.label).first { $0.hasPrefix("read ") }
                r.check(false, "outcome=card reply=\(reply.flatMap { WholeChecks.parseReply($0)?.shape.text } ?? "none")")
            } else {
                let msg = v.texts(v.panel).map(\.label).joined(separator: " ")
                r.check(msg == WholeChecks.refusal, "panel=\(q(msg))")
            }
            closeCall(v)
            let left = wholeShape(host, web)
            r.check(left == before, "left=\(left?.text ?? "unreadable")")
            if host == "uikit" || web != nil {
                // The cursor goes back where it was (the UITextView `sel` probe, the page's posted caret).
                let c = wholeCaret(host, web)
                r.check(c == caretBefore, "caret-left=\(c ?? "unreadable") want \(caretBefore ?? "unreadable")")
            } else {
                r.add("caret-left=\(wholeCaret(host, web) ?? "unreadable")")
            }
            return r
        }

        guard v.panel.isEmpty else {
            r.check(false, "outcome=panel msg=\(q(v.texts(v.panel).map(\.label).joined(separator: " ")))")
            closeCall(v)
            return r
        }
        // A reply that wraps can sit above the card's `→` row (walk-back probe run 135): look among all its texts.
        if !v.texts(v.card).contains(where: { $0.label.hasPrefix("read ") }) {
            let again = poll(5, every: 0.5) { w in w.texts(w.card).contains { $0.label.hasPrefix("read ") } }
            if let w = again.view, again.met { v = w }
        }
        let texts = v.texts(v.card).map(\.label)
        guard let reply = texts.first(where: { $0.hasPrefix("read ") }), let parsed = WholeChecks.parseReply(reply) else {
            // Never the card's text (a stub reply that does not parse could carry field text): counts and lengths only.
            r.check(false, "reply=unparsed card=\(texts.count) texts, lengths \(texts.map { $0.utf16.count })")
            closeCall(v)
            return r
        }
        r.add("read=\(parsed.ms)")
        r.check(parsed.shape == before, "reply=\(parsed.shape.text)")
        // An accepted read leaves the cursor at the end of the field (recorded only on the SwiftUI field, whose
        // probe follows the text system's selection changes as SwiftUI reports them).
        let caretRead = wholeCaret(host, web)
        if host == "swiftui" {
            r.add("caret-read=\(caretRead ?? "unreadable")")
        } else {
            r.check(caretRead == "\(s.units),0", "caret-read=\(caretRead ?? "unreadable")")
        }
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
        guard writingEnded(since: t1, "kb", &r) else { return r }

        // The protly key is Undo now. Its row is found first (a screenshot: a second or two), so the timer starts at the
        // tap, as Replace's does (runs 181-189: undo= was 3.7-6.6 s for a 335-unit insert, most of it this search).
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
        _ = writingEnded(since: t2, "kbundo", &r)
        return r
    }

    /// F02c bug 2: a partial selection at the field's start, up to a line feed, shows no context on either side, as
    /// select all does. It must stay a selection: a copy-only card (no Replace) of exactly the selected units, and the
    /// field unchanged.
    private func wholeHead(_ r0: WholeTry, _ v0: CallView, before: WholeChecks.Shape, host: String,
                           web: ReadWeb?) -> WholeTry {
        var r = r0
        var v = v0
        guard v.panel.isEmpty else {
            r.check(false, "outcome=panel msg=\(q(v.texts(v.panel).map(\.label).joined(separator: " ")))")
            closeCall(v)
            return r
        }
        if !v.texts(v.card).contains(where: { $0.label.hasPrefix("read ") }) {
            let again = poll(5, every: 0.5) { w in w.texts(w.card).contains { $0.label.hasPrefix("read ") } }
            if let w = again.view, again.met { v = w }
        }
        let reply = v.texts(v.card).map(\.label).first { $0.hasPrefix("read ") }
        let parsed = reply.flatMap { WholeChecks.parseReply($0) }
        // The card's other texts are never logged: only the reply's shape, or that none parsed.
        r.check(parsed?.shape == WholeChecks.Shape(WholeChecks.headUnits),
                "reply=\(parsed?.shape.text ?? "unparsed") want \(WholeChecks.Shape(WholeChecks.headUnits).text)")
        r.check(v.button("Replace", in: v.card) == nil, "replace=\(v.button("Replace", in: v.card) == nil ? "none" : "offered")")
        closeCall(v)
        let left = wholeShape(host, web)
        r.check(left == before, "left=\(left?.text ?? "unreadable")")
        r.add("caret-left=\(wholeCaret(host, web) ?? "unreadable")")
        return r
    }

    /// The strip's second line after 2 s, then its Cancel while the read still runs: the strip goes, no panel or card
    /// comes, the field is unchanged and the caret is back where it was (the keyboard log must say `cancelled`).
    private func wholeCancel(_ r0: WholeTry, since t0: Date, before: WholeChecks.Shape, caretBefore: String?,
                             host: String, web: ReadWeb?) -> WholeTry {
        var r = r0
        let shown = poll(8, every: 0.3) { v in v.stripText.contains(WholeChecks.progress) }
        guard let v = shown.view, shown.met else {
            r.check(false, "progress=none strip=\(q(shown.view?.stripText))")
            closeCall(shown.view)
            return r
        }
        r.add(String(format: "progress=%.1f", Date().timeIntervalSince(t0)))
        guard let cancel = v.button("Cancel", in: v.strip) else {
            r.check(false, "cancel=none strip=\(q(v.stripText))")
            return r
        }
        d.point(cancel.frame.midX, cancel.frame.midY).tap()
        r.add(String(format: "cancelled=%.1f", Date().timeIntervalSince(t0)))
        d.pause(2.5)  // a step on its way settles (at most about 1 s), then the cursor goes back
        let after = d.callView()
        r.check(after.map { $0.strip.isEmpty && $0.panel.isEmpty && $0.card.isEmpty } ?? false,
                "closed=\(after.map { "\($0.strip.count)/\($0.panel.count)/\($0.card.count)" } ?? "unreadable")")
        let left = wholeShape(host, web)
        r.check(left == before, "left=\(left?.text ?? "unreadable")")
        let c = wholeCaret(host, web)
        r.check(c == caretBefore, "caret-left=\(c ?? "unreadable") want \(caretBefore ?? "unreadable")")
        return r
    }

    /// Replace and its Undo end with the keyboard's own check of the field (the strip says "Replacing the text…"
    /// meanwhile). true when the strip went away without a notice; the seconds since `since` are recorded as `name`.
    private func writingEnded(since: Date, _ name: String, _ r: inout WholeTry) -> Bool {
        let p = poll(WholeChecks.writeTimeout, every: 0.5) { v in v.strip.isEmpty }
        guard let v = p.view, p.met else {
            r.check(false, "\(name)=timeout strip=\(q(p.view?.stripText))")
            return false
        }
        r.add(String(format: "\(name)=%.2f", Date().timeIntervalSince(since)))
        guard v.panel.isEmpty else {
            let msg = v.texts(v.panel).map(\.label).joined(separator: " ")
            r.check(false, "\(name)-notice=\(q(msg))" + (msg == WholeChecks.notice ? "" : " (not the Replace notice)"))
            closeCall(v)
            return false
        }
        return true
    }

    /// Puts the case's draft in the field with its cursor or selection; nil when done, else why not.
    private func wholeSetUp(_ s: WholeChecks.Spec, host: String, web: ReadWeb?) -> String? {
        if let web {
            web.clear()
            guard web.focus(host) else { return "no \(host) frame on the read page" }
            guard protlyUp() else { return "protly keyboard not up on the \(host) field" }
            guard tapHost("rfill-\(s.fill)") else { return "no rfill-\(s.fill) button" }
            // The page's own fill is unseen by the keyboard's proxy (walk-back probe runs 122, 124): Dismiss, then a
            // tap at the field's end makes the page send its state to the keyboard (run 127).
            guard tapHost("dismiss", settle: 1.0) else { return "no dismiss button" }
            guard web.focusEnd(host) else { return "no \(host) frame on the read page" }
            guard protlyUp() else { return "protly keyboard not up after the tap at the field's end" }
            d.pause(0.5)
            if s.selectAll || s.head {
                guard tapHost(s.head ? "rselhead" : "rselall") else { return "no rselall or rselhead button" }
            } else if web.caret(host) != "\(s.cursor),0" {
                // The tap left the caret elsewhere, or the case wants it inside the text: the page puts it at the
                // fill's cursor.
                guard tapHost("rcaret") else { return "no rcaret button" }
            }
            return nil
        }
        d.clearField()
        guard protlyUp() else { return "protly keyboard not up on the \(host) field" }
        guard tapHost("rfill-\(s.fill)") else { return "no rfill-\(s.fill) button" }
        if host == "uikit" {
            // Select all, or the selection set again where the fill put it, with the input delegate told (resync).
            guard tapHost(s.selectAll ? "rselall" : s.head ? "rselhead" : "rsync") else {
                return "no rselall, rselhead or rsync button"
            }
        } else if s.selectAll || s.head || s.cursor != s.units {
            // The fill asks the field for its cursor (HostApp.swift HostView.fill); rselall for the whole text.
            guard WholeChecks.hasTextSelection else { return "the SwiftUI field's selection needs iOS 18" }
            if s.selectAll || s.head {
                guard tapHost(s.head ? "rselhead" : "rselall") else { return "no rselall or rselhead button" }
            }
        } else {
            // The resync: Dismiss, then the field takes the focus again without a tap (the cursor stays at the end).
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

    /// `location,length` of the selection: the `sel` probe (the UITextView's, or HostView's for the SwiftUI field's
    /// bound selection; empty there before iOS 18) or the page's caret.
    private func wholeCaret(_ host: String, _ web: ReadWeb?) -> String? {
        if let web { return web.caret(host) }
        return d.probeValue("sel")
    }

    /// Seconds from `since` until the field equals `exact` (native, UTF-16 units) or has `shape` (web, or no exact
    /// text); nil when it did not within `timeout`.
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

    /// Cancel on the panel, the card or the strip (Done on a notice); nothing when none is shown.
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
