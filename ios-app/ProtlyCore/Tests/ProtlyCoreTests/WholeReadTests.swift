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
        // Above the slowest step the probe saw (286 ms with its settle polls), so a fast host pays nothing for probes'
        // second look.
        XCTAssertEqual(WholeRead.slowStep, 0.2)
        // The old 2 s budget fits no two-walk read (3 s at least, probe runs 149-155); the end and start probes alone
        // take 3 x 0.5 + 2 x 0.5 s.
        XCTAssertGreaterThan(WholeRead.total, 5 * WholeRead.probeWait)
    }

    /// Replace waits for the host, which applies the deletes one by one while the proxy shows the keyboard's own edits
    /// at once and, on web hosts, sends no callback either (run e070adc-172: the contexts and callbacks were still for
    /// 0.5 s from 0.5 s on while the textarea needed 11.9 s for 3247 deletes). The keyboard moves the cursor again only
    /// once the host has had `replaceSettle`: 1.5 s and 4 ms a delete (the slowest measured: 3247 deletes in 11.9 s on
    /// the textarea, 11.8 s on the SwiftUI field, runs 162 and 172, about 3.7 ms each with the UI test's polling), and
    /// gives up 3 s after that.
    func testReplaceWaitsForTheHostInProportion() {
        XCTAssertEqual(WholeRead.quiet, 0.5)
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 0, inserted: 0), 1.5)
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 3247, inserted: 29), 14.517, accuracy: 0.001)
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 4000, inserted: 0), 17.5, accuracy: 0.001)
        XCTAssertEqual(WholeRead.replaceLimit(deletes: 4000, inserted: 0), 20.5, accuracy: 0.001)
        // The slowest measured rate, with the UI test's polling in it, still ends before the keyboard moves again.
        XCTAssertGreaterThan(WholeRead.replaceSettle(deletes: 3247, inserted: 29), 11.92)
        XCTAssertGreaterThan(WholeRead.replaceSettle(deletes: 4000, inserted: 0), 4000 * 0.0037)
        // Undo of a long Replace inserts the read text in one go: the host needed 2.5-6.6 s for 3247 units (runs 162,
        // 172, 181, with the UI test's polling); its check walk at 1.6 s found the field still changing (run 181).
        XCTAssertEqual(WholeRead.replaceSettle(deletes: 29, inserted: 3247), 4.863, accuracy: 0.001)
    }

    // MARK: Walks on a fake field

    /// The host: `text` with the cursor at `pos` (UTF-16), a before-context of at most `window` units and an
    /// after-context up to the next line feed. `byCharacters`: a move counts characters (WebKit with emoji).
    struct Field {
        var text: [UInt16]
        var pos: Int
        var window = 60
        var byCharacters = false
        /// Positions where the before-context shows empty (a window on its way, run 162 swiftui long t2) until the
        /// cursor has left them once.
        var blanks: Set<Int> = []
        /// Positions where the after-context shows empty mid-line (run 0f1bcd6-185 uikit cancel), until the cursor has
        /// left them once.
        var blankAfter: Set<Int> = []

        var before: [UInt16] { blanks.contains(pos) ? [] : Array(text[max(0, pos - window)..<pos]) }
        var after: [UInt16] { blankAfter.contains(pos) ? [] : Array(text[pos...].prefix { $0 != 10 }) }

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
    private func walkBack(_ f: inout Field, cap: Int = WholeRead.cap, shifted: Bool = false,
                          positions: UnsafeMutablePointer<[Int]>? = nil) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = BackWalk(cap: cap, shifted: shifted)
        var net: Int? = 0
        for _ in 0..<10_000 {
            let k = w.plan(before: f.before, after: f.after)
            let b0 = f.before, a0 = f.after
            let from = f.pos
            positions?.pointee.append(from)
            let changed = f.move(-k)
            let changedContexts = changed && (f.before != b0 || f.after != a0)
            var s = w.landed(changed: changedContexts, before: f.before, after: f.after)
            if case .retry(let m) = s {
                // The driver undoes the probe; the blank it stood on has caught up by then.
                net = net.map { $0 - 1 }
                f.blanks.remove(from)
                let b1 = f.before, a1 = f.after
                let moved = f.move(m)
                s = w.undone(changed: moved && (f.before != b1 || f.after != a1), before: f.before, after: f.after)
                if case .moved = s {} else { return (s, w.units, net) }
            }
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .phantom: net = nil
            case .done: return (s, w.units, net)
            case .retry: return (s, w.units, net)
            case .failed(_, let moved):
                net = net.flatMap { n in moved.map { n + $0 } }
                return (s, w.units, net)
            }
        }
        XCTFail("no end")
        return (.failed("loop", moved: nil), w.units, nil)
    }

    private func walkForward(_ f: inout Field, cap: Int = WholeRead.cap, resync: Bool = false,
                             stale: (before: [UInt16], after: [UInt16])? = nil) -> (step: WalkStep, units: [UInt16], net: Int?) {
        var w = ForwardWalk(cap: cap, resyncFirst: resync)
        var net: Int? = 0
        var shown = stale
        for _ in 0..<10_000 {
            // `stale`: what the keyboard was shown before the first step (the host moved the caret without telling it).
            let b0 = shown?.before ?? f.before, a0 = shown?.after ?? f.after
            shown = nil
            let from = f.pos
            let k = w.plan(after: a0)
            let changed = f.move(k)
            var s = w.landed(changed: changed && (f.before != b0 || f.after != a0), before: f.before, after: f.after)
            if case .retry(let m) = s {
                // The driver undoes the probe; the blank it stood on has caught up by then.
                net = net.map { $0 + 1 }
                f.blankAfter.remove(from)
                let b1 = f.before, a1 = f.after
                let moved = f.move(m)
                s = w.undone(changed: moved && (f.before != b1 || f.after != a1), before: f.before, after: f.after)
                if case .moved = s {} else { return (s, w.units, net) }
            }
            switch s {
            case .moved(let d): net = net.map { $0 + d }
            case .phantom, .retry: net = nil
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

    /// The second walk back steps elsewhere (silent-failure review): a host slow at one place in the first walk (a
    /// false start whose probe showed late) must not meet the second walk at the same place. Its jumps are planned
    /// from the context without its first unit, which keeps them changing the context and off low surrogates.
    func testTheSecondWalkBackStepsElsewhereAndReadsTheSame() {
        let t = u(draft)
        var f = Field(text: t, pos: t.count)
        var p1: [Int] = [], p2: [Int] = []
        let first = walkBack(&f, positions: &p1)
        f.pos = t.count
        let second = walkBack(&f, shifted: true, positions: &p2)
        XCTAssertEqual(first.step, .done)
        XCTAssertEqual(second.step, .done)
        XCTAssertEqual(first.units, t)
        XCTAssertEqual(second.units, t)
        // Away from the start, where the last steps and the probe meet whatever the jumps; one jump may still meet
        // (here the first: the first walk's jump was one short of the window already).
        let shared = Set(p1.dropFirst().filter { $0 > 2 }).intersection(p2.dropFirst())
        XCTAssertLessThanOrEqual(shared.count, 1, "the walks share \(shared.sorted()) of \(p1), \(p2)")
        // Emoji and repeated text stay safe.
        let e = u(String(repeating: "Send me the notes \u{1F44D}. ", count: 30))
        var g = Field(text: e, pos: e.count)
        XCTAssertEqual(walkBack(&g, shifted: true).units, e)
        let r = u(String(repeating: "Thanks for the help ", count: 60))
        var h = Field(text: r, pos: r.count)
        XCTAssertEqual(walkBack(&h, shifted: true).units, r)
        var w = BackWalk(cap: 100, shifted: true)
        XCTAssertEqual(w.plan(before: u("abcdef")), 4)
        XCTAssertEqual(w.plan(before: u("ab")), 1)
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

    /// Code review: one emoji over and over fits a move of k units and a move of k characters alike, so a web view
    /// would read half the field and both walks would agree. A step whose characters cross more units than k and fit
    /// either way is refused (`characters`), on any host.
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
        // Nothing showed: the move may still land later (silent-failure review), so it cannot be named.
        XCTAssertEqual(w.landed(changed: false, before: u("hello world"), after: []), .failed("stuck", moved: nil))
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

    /// A probe that shows text before the cursor (a false start: the before-context was empty mid-field), or gains a
    /// unit at the after-context's front, crossed a unit it cannot name (guessing it corrupted texts: run
    /// 3293a10-138). The walk asks to undo the probe and look again, up to `maxRetries` times; then it is bad.
    func testAFalseStartIsUndoneAndLookedAtAgain() {
        var w = BackWalk(cap: 100)
        _ = w.plan(before: [], after: u("cd"))
        XCTAssertEqual(w.landed(changed: true, before: u("ab"), after: u("bcd")), .retry(1))
        // The undo lands where the probe started: the after-context is the one the probe saw.
        XCTAssertEqual(w.undone(changed: true, before: u("ab"), after: u("cd")), .moved(1))
        XCTAssertEqual(w.units, [], "nothing guessed")
        var v = BackWalk(cap: 100)
        _ = v.plan(before: [], after: u("cd"))
        XCTAssertEqual(v.landed(changed: true, before: [], after: u("xcd")), .retry(1))
        // An undo that changed nothing, or landed elsewhere, cannot be named: the walk stops.
        XCTAssertEqual(v.undone(changed: false, before: [], after: u("xcd")), .failed("badUndo", moved: nil))
        var x = BackWalk(cap: 100)
        _ = x.plan(before: [], after: u("cd"))
        _ = x.landed(changed: true, before: u("ab"), after: u("bcd"))
        XCTAssertEqual(x.undone(changed: true, before: u("ab"), after: u("zz")), .failed("badUndo", moved: nil))
    }

    func testFalseStartsStopTheWalkAfterTheRetries() {
        var w = BackWalk(cap: 100)
        for _ in 0..<BackWalk.maxRetries {
            _ = w.plan(before: [], after: u("cd"))
            XCTAssertEqual(w.landed(changed: true, before: u("ab"), after: u("bcd")), .retry(1))
            XCTAssertEqual(w.undone(changed: true, before: [], after: u("cd")), .moved(1))
        }
        _ = w.plan(before: [], after: u("cd"))
        XCTAssertEqual(w.landed(changed: true, before: u("ab"), after: u("bcd")), .failed("falseStart", moved: -1))
    }

    /// Run 162 swiftui long t2: an empty before-context mid-field outlived the 0.3 s wait. Undone and looked at again
    /// once it caught up, the walk reads the field exactly.
    func testAWalkThroughBlanksReadsExactly() {
        let t = u(draft)
        var f = Field(text: t, pos: t.count, window: 25)
        f.blanks = [t.count - 30, t.count - 90, 40]
        // Blanks only where a step lands (so the walk sees them): plant them on the walk's own path.
        var probe = f
        probe.blanks = []
        var path: [Int] = []
        var w = BackWalk(cap: 4000)
        while probe.pos > 0 {
            let k = w.plan(before: probe.before, after: probe.after)
            _ = probe.move(-k)
            path.append(probe.pos)
            _ = w.landed(changed: true, before: probe.before, after: probe.after)
        }
        f.blanks = Set([path[1], path[3], path[path.count / 2]].filter { $0 > 0 })
        XCTAssertEqual(f.blanks.count, 3)
        let bw = walkBack(&f)
        XCTAssertEqual(bw.step, .done)
        XCTAssertEqual(bw.units, t)
        XCTAssertEqual(bw.net, -t.count)
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
        // A change that shows no line feed before the cursor: a false end, undone and looked at again
        // (testAFalseEndIsUndoneAndLookedAtAgain); with no before-context at all, not a move the walk can name.
        var x = ForwardWalk(cap: 100)
        _ = x.plan(after: [])
        XCTAssertEqual(x.landed(changed: true, before: u("bc"), after: []), .retry(-1))
        var y = ForwardWalk(cap: 100)
        _ = y.plan(after: [])
        XCTAssertEqual(y.landed(changed: true, before: [], after: u("q")), .failed("badStep", moved: 1))
    }

    /// Runs 163 textarea and lexical `mid`, `sel`: the page moved the caret without telling the keyboard, so the
    /// first step forward from the contexts it was shown fits nothing. The first walk may count that one step as a
    /// resync, and it is one unit (design review: a jump planned from a stale window can be longer than the way to the
    /// end, which the host would cut short while the record counted all of it): one unit, unread at most.
    func testTheFirstForwardStepMayResync() {
        let t = u(draft)
        var f = Field(text: t, pos: 30)
        let stale = (before: Array(t[0..<10]), after: Array(t[10...].prefix { $0 != 10 }))
        let fw = walkForward(&f, resync: true, stale: stale)
        XCTAssertEqual(fw.step, .done)
        XCTAssertEqual(f.pos, t.count)
        XCTAssertEqual(fw.net, t.count - 30, "the resync step counts its one unit")
        XCTAssertEqual(fw.units, Array(t[31...]), "all but the resync's one unit")
        var g = Field(text: t, pos: 30)
        let gw = walkForward(&g, resync: false, stale: stale)
        guard case .failed(let why, _) = gw.step else { return XCTFail("\(gw.step)") }
        XCTAssertEqual(why, "badStep")
        // Only the first step: a later one that fits nothing stops the walk.
        var w = ForwardWalk(cap: 100, resyncFirst: true)
        XCTAssertEqual(w.plan(after: u("abcdef")), 1, "the first step of a walk that may resync is one unit")
        XCTAssertEqual(w.landed(changed: true, before: u("qq"), after: u("zz")), .moved(1))
        XCTAssertEqual(w.resyncs, 1)
        XCTAssertEqual(w.plan(after: u("abcdef")), 5)
        XCTAssertEqual(w.landed(changed: true, before: u("qq"), after: u("zz")), .failed("badStep", moved: 5))
    }

    /// A first step that fits reads its unit like any other; a walk that may not resync jumps at once.
    func testTheResyncStepIsOneUnitThatFitsAsUsual() {
        var w = ForwardWalk(cap: 100, resyncFirst: true)
        XCTAssertEqual(w.plan(after: u("abcdef")), 1)
        XCTAssertEqual(w.landed(changed: true, before: u("xa"), after: u("bcdef")), .moved(1))
        XCTAssertEqual(w.resyncs, 0)
        XCTAssertEqual(w.units, u("a"))
        var x = ForwardWalk(cap: 100)
        XCTAssertEqual(x.plan(after: u("abcdef")), 5)
        // Never inside an emoji: two units over a surrogate pair.
        var y = ForwardWalk(cap: 100, resyncFirst: true)
        XCTAssertEqual(y.plan(after: u("\u{1F602}abc")), 2)
    }

    /// Run 0f1bcd6-185 uikit cancel: an after-context that showed empty mid-line made the probe cross a letter, not a
    /// line feed. Such a false end is undone (one unit back, checked against the after-context) and looked at again,
    /// at most `maxRetries` times a walk, as a false start on the way back.
    func testAFalseEndIsUndoneAndLookedAtAgain() {
        let t = u(draft)
        var f = Field(text: t, pos: 40)
        f.blankAfter = [45, 52, 130]
        // The walk lands on 45 and 52 only if its jumps do: put blanks where the jumps from 40 land.
        var g = Field(text: t, pos: 40)
        var w0 = ForwardWalk(cap: WholeRead.cap)
        var stops: [Int] = []
        while stops.count < 4 {
            _ = g.move(w0.plan(after: g.after))
            _ = w0.landed(changed: true, before: g.before, after: g.after)
            stops.append(g.pos)
        }
        f.blankAfter = Set(stops.prefix(3).filter { t[$0] != 10 })
        XCTAssertFalse(f.blankAfter.isEmpty)
        let fw = walkForward(&f)
        XCTAssertEqual(fw.step, .done)
        XCTAssertEqual(fw.units, Array(t[40...]))
        XCTAssertEqual(fw.net, t.count - 40)
        // One by one, and the limit.
        var w = ForwardWalk(cap: 100)
        XCTAssertEqual(w.plan(after: []), 1)
        XCTAssertEqual(w.landed(changed: true, before: u("ab x"), after: u("yz")), .retry(-1))
        XCTAssertEqual(w.undone(changed: true, before: u("ab "), after: u("xyz")), .moved(-1))
        XCTAssertEqual(w.retries, 1)
        XCTAssertEqual(w.units, [])
        // An undo that shows something else cannot be named.
        _ = w.plan(after: [])
        XCTAssertEqual(w.landed(changed: true, before: u("ab x"), after: u("yz")), .retry(-1))
        XCTAssertEqual(w.undone(changed: true, before: u("q"), after: u("qq")), .failed("badUndo", moved: nil))
        var x = ForwardWalk(cap: 100)
        for _ in 0..<ForwardWalk.maxRetries {
            _ = x.plan(after: [])
            XCTAssertEqual(x.landed(changed: true, before: u("ab x"), after: u("yz")), .retry(-1))
        }
        _ = x.plan(after: [])
        XCTAssertEqual(x.landed(changed: true, before: u("ab x"), after: u("yz")), .failed("falseEnd", moved: 1))
    }

    /// A step that fit nothing may be judged again on contexts read a moment later (run 185: a pair of contexts caught
    /// half-updated): judging changes nothing until a step fits.
    func testAStepThatFitNothingCanBeJudgedAgain() {
        var w = ForwardWalk(cap: 100)
        XCTAssertEqual(w.plan(after: u("abcdef")), 5)
        XCTAssertEqual(w.landed(changed: true, before: u("qq"), after: u("zz")), .failed("badStep", moved: 5))
        XCTAssertEqual(w.landed(changed: true, before: u("xabcde"), after: u("f")), .moved(5))
        XCTAssertEqual(w.units, u("abcde"))
        var r = ForwardWalk(cap: 100, resyncFirst: true)
        XCTAssertEqual(r.plan(after: u("abcdef")), 1)
        XCTAssertEqual(r.landed(changed: true, before: u("xa"), after: u("bcdef")), .moved(1))
        XCTAssertEqual(r.resyncs, 0)
        var b = BackWalk(cap: 100)
        XCTAssertEqual(b.plan(before: u("hello world")), 10)
        XCTAssertEqual(b.landed(changed: true, before: u("xyz"), after: u("qqqqqqqqqqqqq")), .failed("badStep", moved: -10))
        XCTAssertEqual(b.landed(changed: true, before: u("h"), after: u("ello world")), .moved(-10))
        XCTAssertEqual(b.units, u("ello world"))
    }

    /// The limits of the resync when the host already had the caret at the end: if the contexts stay stale, the step
    /// is stuck and the read refused (nothing moved, the record exact); if they change to show the real place, the
    /// one-unit step counts one unit the caret never moved.
    func testAResyncAtTheEndIsStuckOrOneUnitOff() {
        let t = u(draft)
        var f = Field(text: t, pos: t.count)
        let stale = (before: Array(t[0..<10]), after: Array(t[10...].prefix { $0 != 10 }))
        let fw = walkForward(&f, resync: true, stale: stale)
        XCTAssertEqual(fw.step, .failed("stuck", moved: nil))
        XCTAssertNil(fw.net)
        var w = ForwardWalk(cap: 100, resyncFirst: true)
        XCTAssertEqual(w.plan(after: stale.after), 1)
        XCTAssertEqual(w.landed(changed: true, before: Array(t.suffix(20)), after: []), .moved(1))
        XCTAssertEqual(w.plan(after: []), 1)
        XCTAssertEqual(w.landed(changed: false, before: Array(t.suffix(20)), after: []), .done)
        XCTAssertEqual(w.units, [])
    }

    // MARK: Acceptance

    func testAcceptOnlyAgreeingWalksAndConfirmedEnds() {
        let text = u("the whole field\nsecond line")
        XCTAssertNil(WholeRead.refusal(first: [], back1: text, mid: [], back2: text, last: []))
        // A return that landed 2 units short: the confirming walk crossed the text's last 2 units.
        XCTAssertNil(WholeRead.refusal(first: [], back1: text, mid: Array(text.suffix(2)), back2: text, last: Array(text.suffix(1))))
        XCTAssertEqual(WholeRead.refusal(first: [], back1: text, mid: [], back2: Array(text.dropFirst()), last: []), "disagree")
        // The second walk started from a false end, and the last walk went on past it: never the text's end.
        XCTAssertEqual(WholeRead.refusal(first: [], back1: text, mid: [], back2: text, last: u(" more")), "lastEnd")
        XCTAssertEqual(WholeRead.refusal(first: [], back1: text, mid: u("extra"), back2: text, last: []), "midEnd")
        XCTAssertEqual(WholeRead.refusal(first: [], back1: [], mid: [], back2: [], last: u("x")), "lastEnd")
        // Both walks back stopped at the same false start between the user's cursor and the end: the first walk to
        // the end crossed more than they read.
        XCTAssertNil(WholeRead.refusal(first: Array(text.suffix(6)), back1: text, mid: [], back2: text, last: []))
        XCTAssertEqual(WholeRead.refusal(first: u("x") + Array(text.suffix(6)), back1: text, mid: [], back2: text, last: []),
                       "firstEnd")
        XCTAssertEqual(WholeRead.refusal(first: u("more text") + text, back1: text, mid: [], back2: text, last: []), "firstEnd")
    }
}
