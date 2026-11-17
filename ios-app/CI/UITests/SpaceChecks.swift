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

/// diag/p4-double-space, second run (test5g_space2): Apple's English keyboard as the control, the time window, and a
/// word right after the cursor.
/// - `pr-gap-<n>` / `ap-gap-<n>`: `hello`, a space, `<n>/10` s of pause, a space (solid host), on Protly and on Apple.
/// - `ap-pick1`: Apple, `hel`, a tap on the QuickType `hello`, then one space (Protly's is sp-*-pick1 in run 121).
/// - `pr-word` / `ap-word`: `world`, the caret moved before it with a tap, then `hello` and two spaces (UITextView).
extension PhoneRun {
    static let space2IDs = ["pr-gap-15", "pr-gap-22", "pr-gap-35", "ap-pick1", "ap-gap-15", "ap-gap-22", "ap-gap-35",
                            "ap-word", "pr-word"]
    static let gapAsks: [(id: String, pause: TimeInterval)] = [("15", 1.5), ("22", 2.2), ("35", 3.5)]

    func checksSpace2() {
        let ids = Self.space2IDs
        if notReady(ids) { return }
        var written = Set<String>()

        // Protly, the solid host: the window.
        for g in Self.gapAsks {
            written.insert("pr-gap-\(g.id)")
            gapCase("pr-gap-\(g.id)", apple: false, pause: g.pause)
        }

        // Apple's English keyboard, the solid host (autocorrection on, so QuickType shows).
        d.clearField()
        d.switchToEnglish()
        if d.current() == .english {
            written.insert("ap-pick1")
            applePick("ap-pick1")
            for g in Self.gapAsks {
                written.insert("ap-gap-\(g.id)")
                gapCase("ap-gap-\(g.id)", apple: true, pause: g.pause)
            }
        }

        // The UITextView screen: a word right after the cursor.
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit"])
        d.focusField()
        _ = d.waitForKeyboard()
        if d.current() != .english { d.switchToEnglish() }
        if d.current() == .english {
            written.insert("ap-word")
            wordCase("ap-word", apple: true)
        }
        if d.current() == .protly || d.pick(.protly) || d.cycle(to: .protly, taps: 3) {
            written.insert("pr-word")
            wordCase("pr-word", apple: false)
        }
        for id in ids where !written.contains(id) {
            unreadableLine(id, "keyboard not reached (\(d.current().rawValue))")
        }
    }

    /// P, Q, S or X (as in spaceCase) for the text a try added, and that text.
    static func classifyAdded(before: String, after: String) -> (String, String) {
        guard after.hasPrefix(before) else { return ("X", "not-a-prefix") }
        let added = String(after.dropFirst(before.count))
        if added.hasSuffix(". ") && !added.hasSuffix(".  ") { return ("P", added) }
        if added.contains(".") { return ("Q", added) }
        if added.hasSuffix("  ") { return ("S", added) }
        return ("X", added)
    }

    private func record2(_ id: String, _ evidence: String) {
        var ev = evidence
        let problems = d.takeProblems()
        if !problems.isEmpty { ev += " problems=\(q(problems.joined(separator: "; ")))" }
        write(id, "RECORD", ev)
    }

    private func gapCase(_ id: String, apple: Bool, pause: TimeInterval) {
        d.clearField()
        d.mark(id)
        var seq = ""
        var notes: [String] = []
        for i in 1...3 {
            let before = Self.plainSpaces(d.fieldText() ?? "")
            var gap = -1.0
            if apple {
                guard appleType("hello ") else { break }
                let start = Date()
                d.pause(pause)
                guard appleType(" ", pause: 0) else { break }
                gap = Date().timeIntervalSince(start)
            } else {
                d.type("hello  ", lastGap: pause)
                gap = d.lastGap
            }
            d.pause(0.6)
            let result = Self.classifyAdded(before: before, after: Self.plainSpaces(d.fieldText() ?? ""))
            seq += result.0
            notes.append("\(i):gap=" + String(format: "%.2f", gap) + ":" + q(result.1))
            d.pause(1.0)
        }
        record2(id, "pause=\(pause) seq=\(seq) tries=\(notes.joined(separator: ";")) final=\(q(d.fieldText()))")
    }

    private func applePick(_ id: String) {
        d.clearField()
        d.mark(id)
        var seq = ""
        var notes: [String] = []
        for i in 1...4 {
            let before = Self.plainSpaces(d.fieldText() ?? "")
            guard appleType("hel") else { break }
            d.pause(1.0)
            d.dumpOnce("apple-predictions")
            let predicate = NSPredicate(format: "label ==[c] 'hello' OR label ==[c] %@", "\u{201C}hello\u{201D}")
            let candidates = d.app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
                .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            guard let cell = candidates.first else {
                notes.append("\(i):no-prediction")
                d.clearField()
                continue
            }
            let label = cell.label
            cell.tap()
            d.pause(0.8)
            let picked = Self.plainSpaces(d.fieldText() ?? "")
            guard appleType(" ") else { break }
            d.pause(0.6)
            let after = Self.plainSpaces(d.fieldText() ?? "")
            let result = Self.classifyAdded(before: before, after: after)
            seq += result.0
            let pickAdded = picked.hasPrefix(before) ? String(picked.dropFirst(before.count)) : "not-a-prefix"
            notes.append("\(i):cell=\(q(label)):after-pick=\(q(pickAdded)):after-space=\(q(result.1))")
            d.pause(3.5)  // the next try's spaces must not fall in this try's window
        }
        record2(id, "seq=\(seq) tries=\(notes.joined(separator: ";")) final=\(q(d.fieldText()))")
    }

    private func wordCase(_ id: String, apple: Bool) {
        d.mark(id)
        var notes: [String] = []
        for i in 1...3 {
            d.clearField()
            if apple { appleType("world") } else { d.type("world") }
            d.pause(0.6)
            guard let r = Self.rect(d.probeValue("first-word")) else {
                notes.append("\(i):no-word-frame")
                continue
            }
            d.point(r.minX + 1, r.midY).tap()
            d.pause(0.8)
            let sel = d.probeValue("sel")
            if apple { appleType("hello  ", pause: 0.3) } else { d.type("hello  ") }
            d.pause(0.6)
            notes.append("\(i):sel-before=\(q(sel)):field=\(q(d.fieldText())):sel=\(q(d.probeValue("sel")))")
            d.pause(3.5)
        }
        record2(id, notes.joined(separator: ";"))
    }

    /// Apple's keyboard: its keys are in the accessibility tree, so they are tapped by label (either case) or, for
    /// space, by identifier (TypingChecks.typeOnApple's way).
    @discardableResult
    private func appleType(_ text: String, pause: TimeInterval = 0.15) -> Bool {
        for ch in text {
            let predicate = ch == " " ? NSPredicate(format: "identifier == 'space' OR label == ' '")
                : NSPredicate(format: "label ==[c] %@", String(ch))
            let key = d.app.keyboards.keys.matching(predicate).firstMatch
            guard key.waitForExistence(timeout: 2) else {
                d.fail("Apple's keyboard has no \(String(reflecting: ch)) key")
                return false
            }
            key.tap()
            if pause > 0 { d.pause(pause) }
        }
        return true
    }
}

/// diag/p4-double-space, third run (test5h_space3). In run e0b1b7d-125 each Apple key tapped by element took about
/// 1.5 s, so no two Apple spaces came under 3 s and Apple never made a period: these cases tap Apple's space by
/// coordinate (its frame looked up once), with a positive control.
/// - `pr-pickfast`: Protly, solid host: `hello i` at a quick pace, the bar's right slot (`I`), one space, so the space
///   comes within 3 s of the space after `hello` (the keyboard log's sinceLastSpaceTap says how long it was).
/// - `ap-dbl`: Apple, solid host: `hello`, then XCUICoordinate.doubleTap on its space key (the positive control).
/// - `ap-co-<n>`: Apple, solid host: `hello`, a space tap, `<n>/10` s of pause, a space tap, both by coordinate.
/// - `ap-pick2`: Apple, solid host: `hel`, the QuickType `hello`, then two space taps by coordinate (no pause).
/// - `ap-word2` / `ap-word2d`: Apple, UITextView: `world`, the caret before it, `hello`, then two space taps by
///   coordinate (no pause) / a coordinate double tap.
extension PhoneRun {
    static let space3IDs = ["pr-pickfast", "ap-dbl", "ap-co-0", "ap-co-5", "ap-co-12", "ap-co-20", "ap-pick2",
                            "ap-word2", "ap-word2d"]
    static let coAsks: [(id: String, pause: TimeInterval)] = [("0", 0), ("5", 0.5), ("12", 1.2), ("20", 2.0)]

    func checksSpace3() {
        let ids = Self.space3IDs
        if notReady(ids) { return }
        var written = Set<String>()

        // Protly, the solid host: a pick right after a typed space.
        written.insert("pr-pickfast")
        pickFastCase("pr-pickfast")

        // Apple's English keyboard, the solid host.
        d.clearField()
        d.switchToEnglish()
        if d.current() == .english, let space = appleSpace() {
            written.insert("ap-dbl")
            coordCase("ap-dbl", space: space, pause: nil)
            for c in Self.coAsks {
                written.insert("ap-co-\(c.id)")
                coordCase("ap-co-\(c.id)", space: space, pause: c.pause)
            }
            written.insert("ap-pick2")
            applePick2("ap-pick2", space: space)
        }

        // The UITextView screen: a word right after the cursor, Apple's spaces by coordinate.
        d.app.terminate()
        d.launch(arguments: ["-screen", "uikit"])
        d.focusField()
        _ = d.waitForKeyboard()
        if d.current() != .english { d.switchToEnglish() }
        if d.current() == .english, let space = appleSpace() {
            written.insert("ap-word2")
            appleWordCase("ap-word2", space: space, double: false)
            written.insert("ap-word2d")
            appleWordCase("ap-word2d", space: space, double: true)
        }
        for id in ids where !written.contains(id) {
            unreadableLine(id, "keyboard not reached (\(d.current().rawValue))")
        }
    }

    /// Apple's space key centre from its accessibility frame (one lookup; the taps then go by coordinate).
    private func appleSpace() -> (CGFloat, CGFloat)? {
        let predicate = NSPredicate(format: "identifier == 'space' OR label == ' '")
        let key = d.app.keyboards.keys.matching(predicate).firstMatch
        guard key.waitForExistence(timeout: 3) else {
            d.fail("Apple's keyboard has no space key")
            return nil
        }
        let f = key.frame
        guard f.width > 0, f.height > 0 else {
            d.fail("Apple's space key has no frame")
            return nil
        }
        d.log(String(format: "Apple space key at %.1f,%.1f size %.1fx%.1f", f.minX, f.minY, f.width, f.height))
        return (f.midX, f.midY)
    }

    /// Two taps on Apple's space by coordinate, `pause` seconds apart, or one XCUICoordinate.doubleTap when nil. Returns
    /// the seconds from the end of the first tap to the end of the second as the test saw them (-1 for a double tap).
    private func appleSpaces(_ space: (CGFloat, CGFloat), pause: TimeInterval?) -> Double {
        let p = d.point(space.0, space.1)
        guard let pause else {
            p.doubleTap()
            return -1
        }
        p.tap()
        let start = Date()
        if pause > 0 { d.pause(pause) }
        p.tap()
        return Date().timeIntervalSince(start)
    }

    private func coordCase(_ id: String, space: (CGFloat, CGFloat), pause: TimeInterval?) {
        d.clearField()
        d.mark(id)
        var seq = ""
        var notes: [String] = []
        for i in 1...3 {
            let before = Self.plainSpaces(d.fieldText() ?? "")
            guard appleType("hello") else { break }
            d.pause(0.4)
            let gap = appleSpaces(space, pause: pause)
            d.pause(0.8)
            let result = Self.classifyAdded(before: before, after: Self.plainSpaces(d.fieldText() ?? ""))
            seq += result.0
            notes.append("\(i):gap=" + String(format: "%.2f", gap) + ":" + q(result.1))
            d.pause(3.5)  // the next try's spaces must not fall in this try's window
        }
        let asked = pause.map { String($0) } ?? "doubleTap"
        record2(id, "pause=\(asked) seq=\(seq) tries=\(notes.joined(separator: ";")) final=\(q(d.fieldText()))")
    }

    private func applePick2(_ id: String, space: (CGFloat, CGFloat)) {
        d.clearField()
        d.mark(id)
        var seq = ""
        var notes: [String] = []
        for i in 1...3 {
            let before = Self.plainSpaces(d.fieldText() ?? "")
            guard appleType("hel") else { break }
            d.pause(1.0)
            let predicate = NSPredicate(format: "label ==[c] 'hello' OR label ==[c] %@", "\u{201C}hello\u{201D}")
            let candidates = d.app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
                .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            guard let cell = candidates.first else {
                notes.append("\(i):no-prediction")
                d.clearField()
                continue
            }
            cell.tap()
            d.pause(0.8)
            let picked = Self.plainSpaces(d.fieldText() ?? "")
            let gap = appleSpaces(space, pause: 0)
            d.pause(0.8)
            let result = Self.classifyAdded(before: before, after: Self.plainSpaces(d.fieldText() ?? ""))
            seq += result.0
            let pickAdded = picked.hasPrefix(before) ? String(picked.dropFirst(before.count)) : "not-a-prefix"
            notes.append("\(i):after-pick=\(q(pickAdded)):gap=" + String(format: "%.2f", gap)
                         + ":after-spaces=\(q(result.1))")
            d.pause(3.5)
        }
        record2(id, "seq=\(seq) tries=\(notes.joined(separator: ";")) final=\(q(d.fieldText()))")
    }

    private func appleWordCase(_ id: String, space: (CGFloat, CGFloat), double: Bool) {
        d.mark(id)
        var notes: [String] = []
        for i in 1...3 {
            d.clearField()
            appleType("world")
            d.pause(0.6)
            guard let r = Self.rect(d.probeValue("first-word")) else {
                notes.append("\(i):no-word-frame")
                continue
            }
            d.point(r.minX + 1, r.midY).tap()
            d.pause(0.8)
            let sel = d.probeValue("sel")
            appleType("hello")
            d.pause(0.4)
            let gap = appleSpaces(space, pause: double ? nil : 0)
            d.pause(0.8)
            notes.append("\(i):sel-before=\(q(sel)):gap=" + String(format: "%.2f", gap)
                         + ":field=\(q(d.fieldText())):sel=\(q(d.probeValue("sel")))")
            d.pause(3.5)
        }
        record2(id, notes.joined(separator: ";"))
    }

    /// Protly, the solid host: `hello i` with short key pauses, the bar's right slot (`I`), then one space tap, all with
    /// row 1 measured once (no screenshot between the taps).
    private func pickFastCase(_ id: String) {
        d.clearField()
        guard let row1 = d.rowOne() else {
            unreadableLine(id, "no row 1 on the host")
            return
        }
        let pace = d.keyPause
        d.fixedRow1 = row1
        d.keyPause = 0.1
        defer {
            d.keyPause = pace
            d.fixedRow1 = nil
        }
        d.mark(id)
        var seq = ""
        var notes: [String] = []
        for i in 1...4 {
            let before = Self.plainSpaces(d.fieldText() ?? "")
            let start = Date()
            d.type("hello i")
            d.tapSlot(.right, settle: 0.3)
            d.tapKey(.space)
            let took = Date().timeIntervalSince(start)
            d.pause(0.6)
            let result = Self.classifyAdded(before: before, after: Self.plainSpaces(d.fieldText() ?? ""))
            seq += result.0
            notes.append("\(i):took=" + String(format: "%.2f", took) + ":" + q(result.1))
            d.pause(3.5)  // the next try's first space must not fall in this try's window
        }
        record2(id, "seq=\(seq) tries=\(notes.joined(separator: ";")) final=\(q(d.fieldText()))")
    }
}
