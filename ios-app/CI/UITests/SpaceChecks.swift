import UIKit
import XCTest

/// diag/p4-double-space (a probe branch, never merged): how often two space taps after a word make ". ", per field
/// and per tap kind. The keyboard's side (what KeyboardKit's check saw at each release: the code points of the last
/// two characters, the time since the last space, the result) is in keyboard-log.txt, category p4.
///
/// Fields: `field` (the solid host's SwiftUI TextField), `uikit` (`-screen uikit`, a UITextView), and on `-screen web`
/// `textarea`, `composer` (contenteditable, white-space pre-wrap) and `plain` (contenteditable, white-space normal).
/// Kinds: `en` (`hello`, then two spaces at the driver's pace), `ko` (`안녕`, the same), `fast` and `kofast` (the same
/// words, then XCUICoordinate.doubleTap on space), `pick1` / `pick2` (`teh`, the bar's right slot, then one or two
/// spaces), `hold` (`hello`, a space, then space held 0.6 s: the trackpad, which types nothing by design).
/// The text keeps growing within a case (`hello. hello. ...`), as a user writes sentences. Every line is RECORD with
/// the counts: P (the try's new text ends in one ". "), Q (a period, but other spacing), S (no period, two spaces at
/// the end), X (anything else), ? (unreadable).
extension PhoneRun {
    static let spaceFields = ["field", "uikit", "textarea", "composer", "plain"]
    static let spaceKinds = ["en", "ko", "fast", "kofast"]
    static let spacePickFields = ["uikit", "composer", "plain"]
    static let spacePickKinds = ["pick1", "pick2"]

    /// The same list as checks.py SPACE_IDS.
    static var spaceIDs: [String] {
        spaceFields.flatMap { f in spaceKinds.map { "sp-\(f)-\($0)" } }
            + spacePickFields.flatMap { f in spacePickKinds.map { "sp-\(f)-\($0)" } } + ["sp-uikit-hold"]
    }

    func checksSpace() {
        let ids = Self.spaceIDs
        if notReady(ids) { return }
        // Stop starting cases well before the method's allowance (PhoneChecksUITests.allowance).
        let deadline = Date().addingTimeInterval(2300)
        var written = Set<String>()
        func run(_ id: String, _ kind: String, read: () -> String?, extra: () -> String, reset: () -> Bool) {
            written.insert(id)
            if Date() > deadline {
                unreadableLine(id, "time budget: case not started")
                return
            }
            spaceCase(id, kind: kind, read: read, extra: extra, reset: reset)
        }

        // The solid host. Row 1 is measured here: on the web screen the form accessory bar would read as its top.
        guard let row1 = d.rowOne() else {
            for id in ids { unreadableLine(id, "no row 1 on the host") }
            return
        }
        for kind in Self.spaceKinds {
            run("sp-field-\(kind)", kind, read: { self.d.fieldText() }, extra: { "" }, reset: {
                self.d.clearField()
                return true
            })
        }

        // The UITextView screen.
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit"])
        d.fixedRow1 = row1
        defer { d.fixedRow1 = nil }
        d.focusField()
        let uikitUp = protlyUp()
        for kind in Self.spaceKinds + Self.spacePickKinds + ["hold"] {
            let id = "sp-uikit-\(kind)"
            if !uikitUp {
                written.insert(id)
                unreadableLine(id, "uikit screen: Protly not up")
                continue
            }
            run(id, kind, read: { self.d.fieldText() }, extra: { "" }, reset: {
                self.d.clearField()
                return true
            })
        }

        // The web screen.
        d.app.terminate()
        d.launch(arguments: ["-screen", "web"])
        let web = WebPage(d: d)
        let loaded = web.waitLoaded()
        if loaded { d.log("web page: rects \(d.probeValue("web-rects") ?? "none")") }
        for name in ["plain", "composer", "textarea"] {
            var kinds = Self.spaceKinds
            if Self.spacePickFields.contains(name) { kinds += Self.spacePickKinds }
            for kind in kinds {
                let id = "sp-\(name)-\(kind)"
                if !loaded {
                    written.insert(id)
                    unreadableLine(id, "the web page did not load (state \(q(web.raw())))")
                    continue
                }
                run(id, kind, read: { web.text(name) }, extra: {
                    let n = (web.state()?["nbsp"] as? [String: Any])?[name] as? Int
                    let shown = n.map { String($0) } ?? "unreadable"
                    return " nbsp-at-end=" + shown
                }, reset: {
                    web.clear()
                    return web.focus(name) && self.protlyUp()
                })
            }
        }
        if loaded { web.clear() }
        for id in ids where !written.contains(id) { unreadableLine(id, "probe bug: no case ran") }
    }

    /// One case: `tries` words, each followed by its space taps; the field read after each try.
    private func spaceCase(_ id: String, kind: String, read: () -> String?, extra: () -> String,
                           reset: () -> Bool) {
        guard reset() else {
            unreadableLine(id, "reset or focus failed")
            return
        }
        let tries = kind == "hold" ? 3 : (kind == "kofast" || kind.hasPrefix("pick") ? 6 : 10)
        let word = kind == "ko" || kind == "kofast" ? "안녕" : (kind.hasPrefix("pick") ? "teh" : "hello")
        d.mark(id)
        var before = Self.plainSpaces(read() ?? "")
        var seq = ""
        var odd: [String] = []
        var gaps: [String] = []
        for i in 1...tries {
            d.mark("\(id)-try\(i)")
            var gap = -1.0
            switch kind {
            case "fast", "kofast":
                d.type(word)
                gap = spaceGesture(hold: nil)
            case "pick1":
                d.type(word)
                d.tapSlot(.right, settle: 0.6)
                d.type(" ")
            case "pick2":
                d.type(word)
                d.tapSlot(.right, settle: 0.6)
                d.type("  ", lastGap: d.keyPause)
                gap = d.lastGap
            case "hold":
                d.type(word + " ")
                gap = spaceGesture(hold: 0.6)
            default:
                d.type(word + "  ", lastGap: d.keyPause)
                gap = d.lastGap
            }
            gaps.append(String(format: "%.2f", gap))
            d.pause(0.5)
            guard let raw = read() else {
                seq += "?"
                odd.append("\(i):unreadable")
                continue
            }
            let after = Self.plainSpaces(raw)
            if after.hasPrefix(before) {
                let added = String(after.dropFirst(before.count))
                let c: String
                if added.hasSuffix(". ") && !added.hasSuffix(".  ") {
                    c = "P"
                } else if added.contains(".") {
                    c = "Q"
                } else if added.hasSuffix("  ") {
                    c = "S"
                } else {
                    c = "X"
                }
                seq += c
                if c != "P" { odd.append("\(i):\(q(added))") }
            } else {
                seq += "X"
                odd.append("\(i):not-a-prefix")
            }
            before = after
        }
        func count(_ c: Character) -> Int { seq.filter { $0 == c }.count }
        var ev = "kind=\(kind) tries=\(tries) period=\(count("P")) period-other=\(count("Q")) spaces=\(count("S")) "
        ev += "other=\(count("X")) unreadable=\(count("?")) seq=\(seq) gaps=\(gaps.joined(separator: ","))"
        if !odd.isEmpty { ev += " odd=\(odd.joined(separator: ";"))" }
        ev += extra()
        ev += " final=\(q(before))"
        let problems = d.takeProblems()
        if !problems.isEmpty { ev += " problems=\(q(problems.joined(separator: "; ")))" }
        write(id, "RECORD", ev)
    }

    /// hold nil: a double tap on space (XCUICoordinate.doubleTap); else space pressed for `hold` seconds. Returns the
    /// gesture's own duration in seconds as the test saw it.
    private func spaceGesture(hold: TimeInterval?) -> Double {
        guard let row1 = d.rowOne() else {
            d.fail("no keyboard for a space gesture")
            return -1
        }
        let (x, y) = d.position(of: .space, row1: row1)
        let start = Date()
        if let hold {
            d.point(x, y).press(forDuration: hold)
        } else {
            d.point(x, y).doubleTap()
        }
        let took = Date().timeIntervalSince(start)
        d.pause(d.keyPause)
        return took
    }

    /// U+00A0 read as a space (the web page already does this; native fields may not).
    static func plainSpaces(_ s: String) -> String {
        String(s.map { $0 == "\u{00A0}" ? " " : $0 })
    }
}
