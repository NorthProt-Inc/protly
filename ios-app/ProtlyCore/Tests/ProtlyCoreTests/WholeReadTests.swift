import Foundation
import XCTest
@testable import ProtlyCore

/// K1b: the pure parts of the whole-field read (walk-back probe, docs/research/2026-11-21-walk-back-probe.md on
/// diag/p1-walk-back). A fake field below plays the host: a before-context window of the last `window` units, an
/// after-context that stops at the next line feed, and moves in UTF-16 units (native) or characters (web).
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

    func testFNVMatchesTheProbe() {
        // FNV-1a 32 offset basis for nothing; the probe logged ha=811c9dc5 for an empty after-context.
        XCTAssertEqual(WholeRead.fnv([]), "811c9dc5")
        XCTAssertEqual(WholeRead.fnv(u("a")), "e40c292c")
    }

    // MARK: Budget

    func testTheBudgetStopsOnlyBetweenSteps() {
        XCTAssertEqual(WholeRead.total, 20)
        XCTAssertTrue(WholeRead.canStart(elapsed: 0, wait: WholeRead.moveWait))
        XCTAssertTrue(WholeRead.canStart(elapsed: 19, wait: 1))
        XCTAssertFalse(WholeRead.canStart(elapsed: 19.01, wait: 1))
        XCTAssertFalse(WholeRead.canStart(elapsed: 20, wait: 0.01))
        XCTAssertEqual(WholeRead.cap, 4000)
        XCTAssertEqual(WholeRead.progressAfter, 2)
        XCTAssertEqual(WholeRead.probeWait, 0.5)
        XCTAssertEqual(WholeRead.emptyWait, 0.3)
        // The old 2 s budget fits no two-walk read (3 s at least, probe runs 149-155); the end and start probes alone
        // take 3 x 0.5 + 2 x 0.5 s.
        XCTAssertGreaterThan(WholeRead.total, 5 * WholeRead.probeWait)
    }

    // MARK: Walks on a fake field

    /// The host: `text` with the cursor at `pos` (UTF-16), a before-context of at most `window` units and an
    /// after-context up to the next line feed. `byCharacters`: a move counts characters (WebKit with emoji).
    struct Field {
        var text: [UInt16]
        var pos: Int
        var window = 60
        var byCharacters = false

        var before: [UInt16] { Array(text[max(0, pos - window)..<pos]) }
        var after: [UInt16] { Array(text[pos...].prefix { $0 != 10 }) }

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

    /// Runs a walk to its end: the driver's loop without the waits.
    private func walkBack(_ f: inout Field, cap: Int = WholeRead.cap) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = BackWalk(cap: cap)
        var net: Int? = 0
        for _ in 0..<10_000 {
            let k = w.plan(before: f.before, after: f.after)
            let b0 = f.before, a0 = f.after
            let changed = f.move(-k)
            let changedContexts = changed && (f.before != b0 || f.after != a0)
            let s = w.landed(changed: changedContexts, before: f.before, after: f.after)
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .phantom: net = nil
            case .done: return (s, w.units, net)
            case .failed(_, let moved):
                net = net.flatMap { n in moved.map { n + $0 } }
                return (s, w.units, net)
            }
        }
        XCTFail("no end")
        return (.failed("loop", moved: nil), w.units, nil)
    }

    private func walkForward(_ f: inout Field, cap: Int = WholeRead.cap) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = ForwardWalk(cap: cap)
        var net: Int? = 0
        for _ in 0..<10_000 {
            let k = w.plan(after: f.after)
            let b0 = f.before, a0 = f.after
            let changed = f.move(k)
            let s = w.landed(changed: changed && (f.before != b0 || f.after != a0), before: f.before, after: f.after)
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .phantom: net = nil
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
        var f = Field(text: t, pos: 40)  // cursor in paragraph 1, a window of 60
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
        let t = u(String(repeating: "Thanks for the help ", count: 60))  // period 20, the probe's stuck case
        var f = Field(text: t, pos: t.count)
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(bw.units, t)
    }

    func testAFieldOverTheCapIsRefused() {
        let t = u(String(repeating: "가나다라마바사 ", count: 600))  // 4800 units
        var f = Field(text: t, pos: t.count)
        let bw = walkBack(&f)
        guard case .failed(let why, let moved) = bw.step else { return XCTFail("\(bw.step)") }
        XCTAssertEqual(why, "tooLong")
        XCTAssertNotNil(moved, "the position stays known")
        XCTAssertEqual(bw.net, f.pos - t.count)
        var g = Field(text: t, pos: 0)
        let fw = walkForward(&g)
        guard case .failed(let fwhy, _) = fw.step else { return XCTFail("\(fw.step)") }
        XCTAssertEqual(fwhy, "tooLong")
        XCTAssertEqual(fw.net, g.pos)
    }

    func testWebTextWithEmojiIsRefusedWithAKnownPosition() {
        let t = u("오늘 고마워 👍 정말로. Send me the notes 🙂 after the call.")
        var f = Field(text: t, pos: t.count, window: 30, byCharacters: true)
        let bw = walkBack(&f)
        guard case .failed(let why, _) = bw.step else { return XCTFail("\(bw.step)") }
        XCTAssertTrue(["characters", "badStep"].contains(why), why)
        // The requested moves undo exactly in a host that counts characters both ways.
        let net = try? XCTUnwrap(bw.net)
        XCTAssertNotNil(net)
        _ = f.move(-(net ?? 0))
        XCTAssertEqual(f.pos, t.count)
    }

    func testNativeTextWithEmojiIsReadExactly() {
        let t = u("오늘 고마워 👍 정말로.\nSend me the notes 🙂 after the call.\n끝 👍👍")
        var f = Field(text: t, pos: t.count, window: 25)
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(bw.units, t)
    }

    func testTheSecondWalkCapIsTheFirstWalksLength() {
        let t = u(draft)
        var f = Field(text: t, pos: t.count)
        let bw = walkBack(&f, cap: 30)
        guard case .failed(let why, _) = bw.step else { return XCTFail("\(bw.step)") }
        XCTAssertEqual(why, "tooLong")
    }

    // MARK: Step checks (BackWalk.landed)

    func testABackStepThatFitsNothingIsBad() {
        var w = BackWalk(cap: 100)
        let k = w.plan(before: u("hello world"))
        XCTAssertEqual(k, 10)
        // The host shows a context from elsewhere (a stale or resynced window).
        XCTAssertEqual(w.landed(changed: true, before: u("xyz"), after: u("qqqqqqqqqqqqq")), .failed("badStep", moved: -10))
    }

    func testANonProbeStepThatChangesNothingIsStuck() {
        var w = BackWalk(cap: 100)
        _ = w.plan(before: u("hello world"))
        XCTAssertEqual(w.landed(changed: false, before: u("hello world"), after: []), .failed("stuck", moved: 0))
    }

    func testTheStartIsAProbeThatChangesNothing() {
        var w = BackWalk(cap: 100)
        XCTAssertEqual(w.plan(before: []), 1)
        XCTAssertEqual(w.landed(changed: false, before: [], after: u("abc")), .done)
    }

    /// Lexical-shaped page (run 7f2f443-135): at the true start a -1 empties the after-context without crossing text.
    func testAPhantomStepIsSkipped() {
        var w = BackWalk(cap: 100)
        _ = w.plan(before: [])
        XCTAssertEqual(w.landed(changed: true, before: [], after: []), .phantom)
        XCTAssertEqual(w.units, [])
    }

    /// A probe that shows text before the cursor (a false start: the before-context was empty mid-field) would put a
    /// guessed unit in the text; and one that gains a unit at the after-context's front crossed text.
    func testAFalseStartIsBad() {
        var w = BackWalk(cap: 100)
        _ = w.plan(before: [])
        XCTAssertEqual(w.landed(changed: true, before: u("ab"), after: u("cd")), .failed("falseStart", moved: -1))
        var v = BackWalk(cap: 100)
        _ = v.plan(before: [])
        XCTAssertEqual(v.landed(changed: true, before: [], after: u("xcd")), .failed("falseStart", moved: -1))
    }

    func testAForwardStepMustShowThePieceBeforeTheCursor() {
        var w = ForwardWalk(cap: 100)
        XCTAssertEqual(w.plan(after: u("abcdef")), 5)
        XCTAssertEqual(w.landed(changed: true, before: u("zzabcde"), after: u("f")), .moved(5))
        XCTAssertEqual(w.plan(after: u("f")), 1)
        XCTAssertEqual(w.landed(changed: true, before: u("zzzzz"), after: []), .failed("badStep", moved: 1))
    }

    func testTheEndIsAProbeThatChangesNothing() {
        var w = ForwardWalk(cap: 100)
        XCTAssertEqual(w.plan(after: []), 1)
        XCTAssertEqual(w.landed(changed: false, before: u("abc"), after: []), .done)
        // A probe over a line feed moves one unit.
        var v = ForwardWalk(cap: 100)
        _ = v.plan(after: [])
        XCTAssertEqual(v.landed(changed: true, before: u("abc\n"), after: u("next")), .moved(1))
        XCTAssertEqual(v.units, [10])
        // A change that shows no line feed before the cursor is not a move the walk can name.
        var x = ForwardWalk(cap: 100)
        _ = x.plan(after: [])
        XCTAssertEqual(x.landed(changed: true, before: u("bc"), after: []), .failed("badStep", moved: 1))
    }

    // MARK: Acceptance

    func testAcceptOnlyAgreeingWalksAndConfirmedEnds() {
        let text = u("the whole field\nsecond line")
        XCTAssertNil(WholeRead.refusal(back1: text, mid: [], back2: text, last: []))
        // A return that landed 2 units short: the confirming walk crossed the text's last 2 units.
        XCTAssertNil(WholeRead.refusal(back1: text, mid: Array(text.suffix(2)), back2: text, last: Array(text.suffix(1))))
        XCTAssertEqual(WholeRead.refusal(back1: text, mid: [], back2: Array(text.dropFirst()), last: []), "disagree")
        // The second walk started from a false end, and the last walk went on past it: never the text's end.
        XCTAssertEqual(WholeRead.refusal(back1: text, mid: [], back2: text, last: u(" more")), "lastEnd")
        XCTAssertEqual(WholeRead.refusal(back1: text, mid: u("extra"), back2: text, last: []), "midEnd")
        XCTAssertEqual(WholeRead.refusal(back1: [], mid: [], back2: [], last: u("x")), "lastEnd")
    }
}
