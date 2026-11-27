import Foundation
import XCTest
@testable import ProtlyCore

/// One-pass whole-field read: the pure parts of WholeRead (safeJump, both step checks, budget, replaceSettle,
/// showsEnd and accept).
final class WholeReadTests: XCTestCase {
    private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

    // MARK: safeJump

    func testSafeJumpIsTheLargestNonPeriod() {
        XCTAssertEqual(WholeRead.safeJump(u("abcdef"), back: true), 5)
        // "abab" has periods 2; k = 3 is not a period ("a" != "b" at offset 3).
        XCTAssertEqual(WholeRead.safeJump(u("abab"), back: true), 3)
        // Three repeated 20-unit sentences: 59, 58... k = 40 and 20 are periods; 59 is not.
        let s = String(repeating: "Thanks for the help ", count: 3)
        XCTAssertEqual(s.utf16.count, 60)
        let k = WholeRead.safeJump(u(s), back: true)
        XCTAssertEqual(k, 59)
        XCTAssertNotEqual(k % 20, 0)
    }

    func testSafeJumpOnAllSameUnitsFallsToOne() {
        XCTAssertEqual(WholeRead.safeJump(u("aaaa"), back: true), 1)
        XCTAssertEqual(WholeRead.safeJump(u("a"), back: true), 1)
        XCTAssertEqual(WholeRead.safeJump(u(""), back: true), 1)
    }

    func testSafeJumpNeverSplitsASurrogatePair() {
        // "x👍y": units x, D83D, DC4D, y. Back by 3 lands before D83D (fine); back by 2 would land before DC4D.
        let t = u("x👍y")
        let kb = WholeRead.safeJump(t, back: true)
        XCTAssertFalse((0xDC00...0xDFFF).contains(t[t.count - kb]), "lands inside a pair")
        let kf = WholeRead.safeJump(t, back: false)
        XCTAssertFalse((0xDC00...0xDFFF).contains(t[kf]), "lands inside a pair")
        // Two units that are one pair: move over both.
        XCTAssertEqual(WholeRead.safeJump(u("👍"), back: true), 2)
        // Never a period either, for every length up to 40 on emoji text.
        let e = u(String(repeating: "a👍", count: 20))
        for n in 1...e.count {
            let w = Array(e.suffix(n))
            let k = WholeRead.safeJump(w, back: true)
            XCTAssertGreaterThanOrEqual(k, 1)
            XCTAssertLessThanOrEqual(k, max(1, n))
            if k < n { XCTAssertFalse((0xDC00...0xDFFF).contains(w[n - k]), "n=\(n) k=\(k)") }
        }
    }

    /// Codex bug 3: a context that is exactly one emoji gave a forward step of one unit, inside the pair
    /// (the after-context stops at a line feed, so a line that ends with one emoji). Both ways it is two.
    func testALoneEmojiIsOneStepOfTwoUnitsBothWays() {
        let e = Array("\u{1F600}".utf16)
        XCTAssertEqual(WholeRead.safeJump(e, back: false), 2)
        XCTAssertEqual(WholeRead.safeJump(e, back: true), 2)
        XCTAssertEqual(WholeRead.safeJump(u("ab"), back: false), 1)
        XCTAssertEqual(WholeRead.safeJump(u("a"), back: false), 1)
        // A forward walk over a line that ends with one emoji reads it whole.
        let t = u("ab\n\u{1F600}\ncd")
        var f = Field(text: t, pos: 3)
        let fw = walkForward(&f)
        XCTAssertEqual(fw.step, .done)
        XCTAssertEqual(fw.units, Array(t[3...]))
    }

    func testFNVMatchesTheProbe() {
        XCTAssertEqual(WholeRead.fnv([]), "811c9dc5")
        XCTAssertEqual(WholeRead.fnv(u("a")), "e40c292c")
    }

    // MARK: Budget and settle

    func testTheBudgetStopsOnlyBetweenSteps() {
        XCTAssertEqual(WholeRead.total, 6)
        XCTAssertTrue(WholeRead.canStart(elapsed: 0, wait: WholeRead.moveWait))
        XCTAssertTrue(WholeRead.canStart(elapsed: 5, wait: 1))
        XCTAssertFalse(WholeRead.canStart(elapsed: 5.01, wait: 1))
        XCTAssertFalse(WholeRead.canStart(elapsed: 6, wait: 0.01))
        XCTAssertEqual(WholeRead.progressAfter, 2)
        XCTAssertEqual(WholeRead.probeWait, 0.5)
        XCTAssertEqual(WholeRead.emptyWait, 0.3)
        XCTAssertGreaterThan(WholeRead.total, 3 * WholeRead.probeWait + WholeRead.emptyWait)
    }

    /// replaceSettle survives as "no new read this soon after a write" and write-echo grace.
    func testReplaceSettleScalesWithDeletesAndInserts() {
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 0, inserted: 0), 1.5)
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 335, inserted: 26), 2.905, accuracy: 0.001)
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 26, inserted: 335), 2.4415, accuracy: 0.001)
    }

    // MARK: Walks on a fake field

    /// The host: `text` with the cursor at `pos` (UTF-16), a before-context of at most `window` units and an
    /// after-context up to the next line feed. `byCharacters`: a move counts characters (WebKit with emoji).
    struct Field {
        var text: [UInt16]
        var pos: Int
        var window = 60
        var byCharacters = false
        var afterCap = Int.max

        var before: [UInt16] { Array(text[max(0, pos - window)..<pos]) }
        var after: [UInt16] { Array(text[pos...].prefix { $0 != 10 }.prefix(afterCap)) }

        mutating func move(_ k: Int) -> Bool {
            let old = pos
            if byCharacters {
                var left = abs(k)
                while left > 0, k < 0 ? pos > 0 : pos < text.count {
                    if k < 0 {
                        pos -= 1
                        if pos > 0, (0xDC00...0xDFFF).contains(text[pos]) { pos -= 1 }
                    } else {
                        pos += 1
                        if pos < text.count, (0xDC00...0xDFFF).contains(text[pos]) { pos += 1 }
                    }
                    left -= 1
                }
            } else {
                pos = min(max(0, pos + k), text.count)
            }
            return pos != old
        }
    }

    private func walkBack(_ f: inout Field) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = BackWalk()
        var net: Int? = 0
        for _ in 0..<10_000 {
            let k = w.plan(before: f.before, after: f.after)
            let b0 = f.before, a0 = f.after
            let changed = f.move(-k)
            let changedContexts = changed && (f.before != b0 || f.after != a0)
            let s = w.landed(changed: changedContexts, before: f.before, after: f.after)
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .done: return (s, w.units, net)
            case .failed(_, let moved):
                net = net.flatMap { n in moved.map { n + $0 } }
                return (s, w.units, net)
            }
        }
        XCTFail("no end")
        return (.failed("loop", moved: nil), w.units, nil)
    }

    private func walkForward(_ f: inout Field) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = ForwardWalk()
        var net: Int? = 0
        for _ in 0..<10_000 {
            let b0 = f.before, a0 = f.after
            let k = w.plan(before: b0, after: a0)
            let changed = f.move(k)
            let s = w.landed(changed: changed && (f.before != b0 || f.after != a0), before: f.before, after: f.after)
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .done: return (s, w.units, net)
            case .failed(_, let moved):
                net = net.flatMap { n in moved.map { n + $0 } }
                return (s, w.units, net)
            }
        }
        XCTFail("no end")
        return (.failed("loop", moved: nil), w.units, nil)
    }

    private let draft: String = {
        let p = (1...5).map { i in String(repeating: "문장 \(i)번은 이렇게 끝나요. ", count: 4) }
        return p.joined(separator: "\n") + "\n\nThe end."
    }()

    func testTheWalksReadTheWholeFieldFromTheWindow() {
        let t = u(draft)
        var f = Field(text: t, pos: 40)
        let fw = walkForward(&f)
        XCTAssertEqual(fw.step, .done)
        XCTAssertEqual(f.pos, t.count)
        XCTAssertEqual(fw.net, t.count - 40)
        XCTAssertEqual(fw.units, Array(t[40...]))
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(f.pos, 0)
        XCTAssertEqual(bw.units, t)
        XCTAssertEqual(bw.net, -t.count)
    }

    func testRepeatedTextNeverStopsTheWalk() {
        let t = u(String(repeating: "Thanks for the help ", count: 60))
        var f = Field(text: t, pos: t.count)
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(bw.units, t)
    }

    func testWebTextWithEmojiIsRefusedWithAKnownPosition() {
        let t = u("오늘 고마워 👍 정말로. Send me the notes 🙂 after the call.")
        var f = Field(text: t, pos: t.count, window: 30, byCharacters: true)
        let bw = walkBack(&f)
        guard case .failed(let why, _) = bw.step else { return XCTFail("\(bw.step)") }
        XCTAssertTrue(["characters", "badStep"].contains(why), why)
        let net = try? XCTUnwrap(bw.net)
        XCTAssertNotNil(net)
        _ = f.move(-(net ?? 0))
        XCTAssertEqual(f.pos, t.count)
    }

    func testRepeatedEmojiThatFitsBothReadingsIsRefused() {
        let t = u(String(repeating: "\u{1F602}", count: 8))
        for web in [true, false] {
            var f = Field(text: t, pos: t.count, window: 30, byCharacters: web)
            let bw = walkBack(&f)
            XCTAssertEqual(bw.step, .failed("characters", moved: -2), "web \(web)")
        }
        XCTAssertEqual(WholeRead.charUnits(t, 2), 4)
        XCTAssertEqual(WholeRead.charUnits(u("ab\u{1F602}"), 2), 3)
        XCTAssertEqual(WholeRead.charUnits(u("ab"), 2), 2)
        XCTAssertNil(WholeRead.charUnits(u("a"), 2))
    }

    func testAWebHostThatClampsAtTheStartIsNotReadShort() {
        for text in ["\u{1F600}\u{1F600}\u{1F600}\nA", "\u{1F600}\nA", "x\u{1F600}\u{1F600}\nAB",
                     "\u{1F600}\u{1F600}\u{1F600}\u{1F600} ok\nA"] {
            let t = u(text)
            for window in [30, 12] {
                var f = Field(text: t, pos: t.count, window: window, byCharacters: true)
                let bw = walkBack(&f)
                if case .done = bw.step {
                    XCTAssertEqual(bw.units, t, "\(text) window \(window): a read that ends must be whole")
                }
            }
        }
    }

    func testAnAfterContextCutShortStillFitsAStepOverALineFeed() {
        let t = u(draft)
        for cap in [21, 8, 1] {
            var f = Field(text: t, pos: t.count, window: 65, afterCap: cap)
            let bw = walkBack(&f)
            XCTAssertEqual(bw.step, .done, "cap \(cap)")
            XCTAssertEqual(bw.units, t, "cap \(cap)")
        }
        var f = Field(text: t, pos: 0, window: 65, afterCap: 21)
        let fw = walkForward(&f)
        XCTAssertEqual(fw.step, .done)
        XCTAssertEqual(fw.units, t)
    }

    func testNativeTextWithEmojiIsReadExactly() {
        let t = u("오늘 고마워 👍 정말로.\nSend me the notes 🙂 after the call.\n끝 👍👍")
        var f = Field(text: t, pos: t.count, window: 25)
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(bw.units, t)
    }

    // MARK: Step checks (BackWalk.landed, ForwardWalk.landed)

    func testABackStepThatFitsNothingIsBad() {
        var w = BackWalk()
        let k = w.plan(before: u("hello world"))
        XCTAssertEqual(k, 10)
        XCTAssertEqual(w.landed(changed: true, before: u("xyz"), after: u("qqqqqqqqqqqqq")), .failed("badStep", moved: -10))
    }

    func testAJumpBackThatShowsNoBeforeContextIsBad() {
        var w = BackWalk()
        XCTAssertEqual(w.plan(before: u("ab\ncd")), 4)
        XCTAssertEqual(w.landed(changed: true, before: [], after: []), .failed("badStep", moved: -4))
        XCTAssertEqual(w.landed(changed: true, before: [], after: u("b")), .moved(-4))
        var x = BackWalk()
        XCTAssertEqual(x.plan(before: u("a\nbcd")), 4)
        XCTAssertEqual(x.landed(changed: true, before: [], after: u("zz")), .failed("badStep", moved: -4))
        XCTAssertEqual(x.landed(changed: true, before: u("a"), after: []), .moved(-4))
    }

    func testANonProbeStepThatChangesNothingIsStuck() {
        var w = BackWalk()
        _ = w.plan(before: u("hello world"))
        XCTAssertEqual(w.landed(changed: false, before: u("hello world"), after: []), .failed("stuck", moved: nil))
    }

    func testTheStartIsAProbeThatChangesNothing() {
        var w = BackWalk()
        XCTAssertEqual(w.plan(before: []), 1)
        XCTAssertEqual(w.landed(changed: false, before: [], after: u("abc")), .done)
    }

    func testAPhantomOrFalseStartFailsAtOnce() {
        var p = BackWalk()
        _ = p.plan(before: [])
        XCTAssertEqual(p.landed(changed: true, before: [], after: []), .failed("phantom", moved: nil))
        var fs = BackWalk()
        _ = fs.plan(before: [], after: u("cd"))
        XCTAssertEqual(fs.landed(changed: true, before: u("ab"), after: u("bcd")), .failed("falseStart", moved: -1))
        var g = BackWalk()
        _ = g.plan(before: [], after: u("cd"))
        XCTAssertEqual(g.landed(changed: true, before: [], after: u("xcd")), .failed("falseStart", moved: -1))
    }

    func testAForwardStepMustShowThePieceBeforeTheCursor() {
        var w = ForwardWalk()
        XCTAssertEqual(w.plan(after: u("abcdef")), 5)
        XCTAssertEqual(w.landed(changed: true, before: u("zzabcde"), after: u("f")), .moved(5))
        XCTAssertEqual(w.plan(after: u("f")), 1)
        XCTAssertEqual(w.landed(changed: true, before: u("zzzzz"), after: []), .failed("badStep", moved: 1))
    }

    func testTheEndIsAProbeThatChangesNothingAndAFalseEndFailsAtOnce() {
        var w = ForwardWalk()
        XCTAssertEqual(w.plan(after: []), 1)
        XCTAssertEqual(w.landed(changed: false, before: u("abc"), after: []), .done)
        var v = ForwardWalk()
        _ = v.plan(after: [])
        XCTAssertEqual(v.landed(changed: true, before: u("abc\n"), after: u("next")), .moved(1))
        XCTAssertEqual(v.units, [10])
        // False end: crossed a non-LF unit -> refused immediately, no retry or undo.
        var x = ForwardWalk()
        _ = x.plan(before: u("b"), after: [])
        XCTAssertEqual(x.landed(changed: true, before: u("bc"), after: []), .failed("falseEnd", moved: 1))
        var y = ForwardWalk()
        _ = y.plan(before: u("b"), after: [])
        XCTAssertEqual(y.landed(changed: true, before: [], after: u("q")), .failed("badStep", moved: nil))
    }

    func testAWindowThatGrewAtTheEndIsTheEnd() {
        var w = ForwardWalk()
        XCTAssertEqual(w.plan(before: u("the end."), after: []), 1)
        XCTAssertEqual(w.landed(changed: true, before: u("Then the end."), after: []), .done)
        XCTAssertEqual(w.units, [])
        var r = ForwardWalk()
        _ = r.plan(before: u("ㅋㅋㅋ"), after: [])
        XCTAssertEqual(r.landed(changed: true, before: u("ㅋㅋㅋㅋ"), after: []), .failed("badStep", moved: nil))
        var q = ForwardWalk()
        _ = q.plan(before: u("ha ㅋㅋㅋ"), after: [])
        XCTAssertEqual(q.landed(changed: true, before: u("ha ㅋㅋㅋㅋ"), after: []), .failed("falseEnd", moved: 1))
        // Host appended during the probe: no end.
        var g = ForwardWalk()
        _ = g.plan(before: u("the end."), after: [])
        XCTAssertEqual(g.landed(changed: true, before: u("Then the end."), after: u(" More")), .failed("badStep", moved: nil))
        var z = ForwardWalk()
        _ = z.plan(after: [])
        XCTAssertEqual(z.landed(changed: true, before: u("q"), after: []), .failed("badStep", moved: nil))
    }
}

/// One-pass whole-field read: pure acceptance rule (WholeRead.accept, WholeRead.showsEnd).
final class OnePassAcceptTests: XCTestCase {
    private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

    func testAcceptsCleanOnePassWhenB1EndsWithFAndFMCrossesNothing() {
        let text = u("First paragraph.\n\nSecond paragraph.")
        let atEnd = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(atEnd), .accept(text))
        let tail = Array(text.suffix(12))
        let mid = WholeRead.OnePass(first: .done(tail), back: .done(text), returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(mid), .accept(text))
        let selAll = WholeRead.OnePass(first: .done([]), back: .done(text), fromSelection: true,
                                       returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(selAll), .accept(text))
    }

    func testRefusesWhenAnyWalkOrReturnFailedOrWasUnclean() {
        let text = u("First line\nSecond line")
        for why in ["stuck", "badStep", "falseEnd", "timeUp"] {
            let r = WholeRead.OnePass(first: .failed(why))
            XCTAssertEqual(WholeRead.accept(r), .refuse("f:\(why)"))
        }
        for why in ["stuck", "badStep", "characters", "falseStart", "phantom", "blank", "timeUp"] {
            let r = WholeRead.OnePass(first: .done([]), back: .failed(why))
            XCTAssertEqual(WholeRead.accept(r), .refuse("b1:\(why)"))
        }
        XCTAssertEqual(WholeRead.accept(WholeRead.OnePass(first: .done([]))), .refuse("b1:missing"))
        let r1Miss = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .notAtEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(r1Miss), .refuse("r1:notAtEnd"))
        let r1Time = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .timeUp)
        XCTAssertEqual(WholeRead.accept(r1Time), .refuse("r1:timeUp"))
        let fmCrossed = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .atEnd, endProbe: .done([10]))
        XCTAssertEqual(WholeRead.accept(fmCrossed), .refuse("fm:crossed"))
        let fmBad = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .atEnd, endProbe: .failed("badStep"))
        XCTAssertEqual(WholeRead.accept(fmBad), .refuse("fm:badStep"))
        let fmMissing = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .atEnd)
        XCTAssertEqual(WholeRead.accept(fmMissing), .refuse("fm:missing"))
        let dirty = WholeRead.OnePass(first: .done([]), back: .done(text), returned: .atEnd, endProbe: .done([]),
                                      clean: false)
        XCTAssertEqual(WholeRead.accept(dirty), .refuse("unclean"))
    }

    func testRefusesWhenB1DoesNotEndWithWhatFCrossed() {
        let text = u("the whole field\nsecond line")
        let wrongTail = WholeRead.OnePass(first: .done(u("x") + Array(text.suffix(6))), back: .done(text),
                                          returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(wrongTail), .refuse("firstEnd"))
        let longerFirst = WholeRead.OnePass(first: .done(u("more ") + text), back: .done(text),
                                            returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(longerFirst), .refuse("firstEnd"))
    }

    /// Codex bug 2: a partial selection at the start of the field up to a line feed shows both contexts empty, like
    /// select all. After the +1 collapse, walk F crosses the rest of the field: refuse instead of treating it as
    /// select all.
    func testRefusesCollapsedSelectionWithTextAfterIt() {
        let rest = u("private notes")
        let full = u("Title\nprivate notes")
        let partial = WholeRead.OnePass(first: .done(rest), back: .done(full), fromSelection: true,
                                        returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(partial), .refuse("partialSelection"))
        let early = WholeRead.OnePass(first: .done([10] + rest), fromSelection: true)
        XCTAssertEqual(WholeRead.accept(early), .refuse("partialSelection"))
    }

    func testEmptyAndWhitespaceFields() {
        let empty = WholeRead.OnePass(first: .done([]), back: .done([]), hasText: false)
        XCTAssertEqual(WholeRead.accept(empty), .empty)
        let ghost = WholeRead.OnePass(first: .done([]), back: .done([]), hasText: true)
        XCTAssertEqual(WholeRead.accept(ghost), .refuse("emptyHasText"))
        let spaces = WholeRead.OnePass(first: .done([]), back: .done(u("  \n\t ")), returned: .atEnd, endProbe: .done([]))
        XCTAssertEqual(WholeRead.accept(spaces), .empty)
        let badSpaces = WholeRead.OnePass(first: .done([]), back: .done(u("   ")), returned: .notAtEnd)
        XCTAssertEqual(WholeRead.accept(badSpaces), .refuse("r1:notAtEnd"))
    }

    func testShowsEndRequiresChangedEmptyAfterNonEmptyAgreeingBefore() {
        let end = u("Second paragraph.")
        XCTAssertTrue(WholeRead.showsEnd(changed: true, before: end, after: [], endBefore: end))
        XCTAssertTrue(WholeRead.showsEnd(changed: true, before: u("paragraph."), after: [], endBefore: end))
        XCTAssertTrue(WholeRead.showsEnd(changed: true, before: u("First. ") + end, after: [], endBefore: end))
        XCTAssertFalse(WholeRead.showsEnd(changed: false, before: end, after: [], endBefore: end))
        XCTAssertFalse(WholeRead.showsEnd(changed: true, before: end, after: u("x"), endBefore: end))
        XCTAssertFalse(WholeRead.showsEnd(changed: true, before: [], after: [], endBefore: end))
        XCTAssertFalse(WholeRead.showsEnd(changed: true, before: u("other."), after: [], endBefore: end))
    }
}
