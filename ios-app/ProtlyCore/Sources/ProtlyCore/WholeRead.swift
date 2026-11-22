import Foundation

/// K1b: the keyboard reads the whole field by moving the cursor, because the proxy shows only a window around it
/// (diagnosis P1a: after a host resync the before-context is the last 2 or 3 sentences, at most about 300 units, and
/// the after-context stops at every line feed). Measured in the walk-back probe (11 CI runs on the iOS 26.5
/// simulator, docs/research/2026-11-21-walk-back-probe.md on diag/p1-walk-back): walk forward to the end, walk back to
/// the start, move forward again, confirm the end, walk back a second time, and accept only when both walks read the
/// same units with no bad step. Anything else is refused: a partial read is never sent (owner decision).
///
/// The pure parts live here; FieldText.swift drives them on the text document proxy.
public enum WholeRead {
    /// The longest field read, in UTF-16 units: the first walk back stops past it (owner decision; the probe read
    /// 3230-3958 units exactly and no 14 038-unit field).
    public static let cap = 4000
    /// The longest whole read, in seconds (owner decision). The keys wait meanwhile.
    public static let total: TimeInterval = 20
    /// The strip says the read is still going after this long.
    public static let progressAfter: TimeInterval = 2
    /// How long a move may take to show in the contexts.
    public static let moveWait: TimeInterval = 1
    /// A probe step (one unit past an empty context): no change for this long is the end or the start.
    public static let probeWait: TimeInterval = 0.5
    /// A step slower than this to show (probe runs 154-155: 286 ms at most, 26-33 ms at the median) marks a slow host:
    /// from then on a probe that saw no change gets a second look before it counts as the end or the start.
    public static let slowStep: TimeInterval = 0.2
    /// An empty before-context mid-field comes back within this long (probe run 153); only then is it probed.
    public static let emptyWait: TimeInterval = 0.3
    /// The poll interval; a step has settled when two polls in a row agree, at most `settlePolls` more polls.
    public static let poll: TimeInterval = 0.02
    public static let settlePolls = 5

    /// Replace: the host applies the deletes one by one (runs 162, 172: 7-12 s for 3247, about 3-3.7 ms each) while
    /// the proxy shows the keyboard's own edits at once; on web hosts neither the contexts nor the host's callbacks
    /// change meanwhile (run e070adc-172). So the keyboard waits `replaceSettle` before it moves the cursor again (a
    /// move sent while the Lexical-shaped page was still deleting left it empty, run 172), then until the contexts have
    /// been still `quiet` and show the result, at most until `replaceLimit`.
    public static let quiet: TimeInterval = 0.5

    /// 1.5 s, 4 ms a delete and 2.5 ms an inserted unit: above every Replace measured in CI (3247 deletes: 11.9 s at
    /// most, with the UI test's polling in it; native hosts' last callback at 6.4-9.0 s, runs 181 and 185) and Undo's
    /// one long insert (3247 units: 2.9-8.5 s as the UI test saw it, no callback from the host). A bound from
    /// measurements, not a signal from the host: web hosts send no callback at all (run 172).
    public static func replaceSettle(deletes: Int, inserted: Int) -> TimeInterval {
        1.5 + 0.004 * Double(deletes) + 0.0025 * Double(inserted)
    }

    /// Replace gives up 3 s after `replaceSettle` (20.5 s for 4000 deletes).
    public static func replaceLimit(deletes: Int, inserted: Int) -> TimeInterval {
        replaceSettle(deletes: deletes, inserted: inserted) + 3
    }

    /// A step that may wait `wait` s still ends within `total`: the cap stops a read only between steps, so a step
    /// on its way always settles (Cancel's record, CursorReturn, never guesses about it).
    public static func canStart(elapsed: TimeInterval, wait: TimeInterval) -> Bool {
        elapsed + wait <= total
    }

    static func isLow(_ x: UInt16) -> Bool { (0xDC00...0xDFFF).contains(x) }

    /// The UTF-16 units the last `k` characters of `u` take, as a web view counts them (a surrogate pair is one); nil
    /// when `u` holds fewer.
    public static func charUnits(_ u: [UInt16], _ k: Int) -> Int? {
        var i = u.count
        for _ in 0..<k {
            guard i > 0 else { return nil }
            i -= 1
            if i > 0, isLow(u[i]), (0xD800...0xDBFF).contains(u[i - 1]) { i -= 1 }
        }
        return u.count - i
    }

    /// The step for a context `u` that ends (back) or starts (forward) at the cursor: the largest k < u.count that is
    /// not a period of `u` (so the move must change the context: the same context k units away would give `u` period
    /// k; run 7f2f443-135 got stuck on repeated sentences) and does not land the cursor before a low surrogate (run
    /// 3182f20-145 lost units on emoji). 1, or 2 when 1 would split a pair, below that.
    public static func safeJump(_ u: [UInt16], back: Bool) -> Int {
        let n = u.count
        // One unit lands at index 1 either way: never there when it is a pair's low half (tower review of f0533ae: a
        // forward step over a lone emoji split it).
        guard n > 2 else { return n == 2 && isLow(u[1]) ? 2 : 1 }
        var k = n - 1
        while k > 1 {
            if !isLow(u[back ? n - k : k]) {
                var periodic = true
                for i in 0..<(n - k) where u[i] != u[i + k] {
                    periodic = false
                    break
                }
                if !periodic { return k }
            }
            k -= 1
        }
        return isLow(u[back ? n - 1 : 1]) ? 2 : 1
    }

    /// FNV-1a 32 over UTF-16 units, 8 hex digits: logs and the CI stub name a text by it, never by its content.
    public static func fnv<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        var h: UInt32 = 0x811C_9DC5
        for x in units {
            h ^= UInt32(x)
            h = h &* 0x0100_0193
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    public static func lineFeeds<C: Collection>(_ units: C) -> Int where C.Element == UInt16 {
        units.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    /// Where both have units, they agree: the shorter one is the longer one's suffix (`atEnd`) or prefix.
    static func agree(_ a: [UInt16], _ b: [UInt16], atEnd: Bool) -> Bool {
        let n = min(a.count, b.count)
        return atEnd ? a.suffix(n).elementsEqual(b.suffix(n)) : a.prefix(n).elementsEqual(b.prefix(n))
    }

    /// The shorter of two before-contexts is the end of the longer one: the same place, seen through windows.
    public static func agreeAtEnd(_ a: [UInt16], _ b: [UInt16]) -> Bool { agree(a, b, atEnd: true) }

    static func hasSuffix(_ a: [UInt16], _ b: [UInt16]) -> Bool {
        b.count <= a.count && a.suffix(b.count).elementsEqual(b)
    }

    /// The verdict on a read whose walks all ended where they should (the forward walks at the end, the walks back at
    /// the start): nil = accept, else why not. `mid` and `last` are what the walks that confirmed the end crossed
    /// after each return move: a return that landed a few units short (probe runs 154, 155) walks the text's last
    /// units again; anything else means a walk back began short of the end (a false end), so the read is refused.
    /// `first` (the walk from the user's cursor to the end) must be the read's end too: two walks back that stopped at
    /// the same false start after the cursor would agree with each other, never with it.
    public static func refusal(first: [UInt16], back1: [UInt16], mid: [UInt16], back2: [UInt16], last: [UInt16]) -> String? {
        if back1 != back2 { return "disagree" }
        if !hasSuffix(back1, first) { return "firstEnd" }
        if !hasSuffix(back1, mid) { return "midEnd" }
        if !hasSuffix(back2, last) { return "lastEnd" }
        return nil
    }
}

/// What one step of a walk found.
public enum WalkStep: Equatable, Sendable {
    /// The step fits the contexts: the cursor moved by this many UTF-16 units.
    case moved(Int)
    /// A probe at the start that changed the contexts without crossing text (the Lexical-shaped page): no text; the
    /// cursor's position is no longer known for sure.
    case phantom
    /// The walk reached its end (forward) or the start (back).
    case done
    /// A probe at an empty before-context crossed a unit it cannot name (a false start: the window was on its way).
    /// The driver moves by this many units to undo it, then asks BackWalk.undone, then plans again.
    case retry(Int)
    /// The walk stopped short. `moved`: the move the walk asked for (the host applies the requested offset; only the
    /// contexts were not as expected), nil when not even that is known (a move that showed nothing may still land).
    case failed(String, moved: Int?)
}

/// One walk back to the start. `plan` gives the next step, `landed` judges it from the contexts once it settled.
public struct BackWalk: Sendable {
    /// False starts a walk may undo and look at again (run 162: one in 9 native reads of 3247 units, on SwiftUI; the
    /// probe saw up to 3 a walk at 3958 units without the 0.3 s wait). Each costs under 1 s.
    public static let maxRetries = 5
    public let cap: Int
    /// The pieces moved over, nearest the end first.
    private var pieces: [[UInt16]] = []
    public private(set) var count = 0
    public private(set) var retries = 0
    private var b0: [UInt16] = []
    private var a0: [UInt16] = []
    private var k = 0
    /// For the log after a step that fits nothing: did the before- and after-context fit the planned move?
    public private(set) var fit = (before: true, after: true)

    /// The second walk back plans its jumps from the context without its first unit, so it lands elsewhere than the
    /// first: a host slow at one place (a false start whose probe showed late) does not meet both walks there
    /// (silent-failure review). Such a jump still changes the context (a period of the context is one of its tail)
    /// and lands on the same unit checks.
    private let shifted: Bool

    public init(cap: Int, shifted: Bool = false) {
        self.cap = cap
        self.shifted = shifted
    }

    /// The units walked over, in field order.
    public var units: [UInt16] { pieces.reversed().flatMap { $0 } }

    /// Units to move back (always > 0). An empty before-context is probed with one unit (the driver waits
    /// `WholeRead.emptyWait` first for it to come back).
    public mutating func plan(before: [UInt16], after: [UInt16] = []) -> Int {
        b0 = before
        a0 = after
        if before.isEmpty {
            k = 1
        } else if shifted, before.count > 2 {
            k = WholeRead.safeJump(Array(before.dropFirst()), back: true)
        } else {
            k = WholeRead.safeJump(before, back: true)
        }
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if b0.isEmpty {
            guard changed else { return .done }
            // Text before the cursor although the context was empty, or a unit gained at the after-context's front:
            // the probe crossed text it cannot name (a false start mid-field; run 3293a10-138 put a guessed unit in).
            let gained = !a1.isEmpty && a1 != a0 && WholeRead.agree(Array(a1.dropFirst()), a0, atEnd: false)
            if !b1.isEmpty || gained {
                guard retries < Self.maxRetries else { return .failed("falseStart", moved: -1) }
                retries += 1
                return .retry(1)
            }
            return .phantom
        }
        guard changed else { return .failed("stuck", moved: nil) }
        // A jump below the context's length always leaves text before the cursor, so an empty before-context is no
        // evidence (an empty context agrees with anything; silent-failure review, round 2). The after-context must then
        // show the piece crossed (a blank on its way: the next probe finds the false start); with nothing to show
        // there either (an empty after-context, or a piece that starts with a line feed) the step names nothing. A
        // step over the whole context (one unit, or one emoji) may reach the start.
        let shown = Array(b0.suffix(k).prefix { $0 != 10 })
        guard !b1.isEmpty || k >= b0.count || (!shown.isEmpty && !a1.isEmpty) else {
            fit = (false, a1.isEmpty)
            return .failed("badStep", moved: -k)
        }
        // The after-context stops at a line feed: when the piece crossed holds one, the after-context must be exactly
        // the piece up to it, not only agree where both have units (tower review of f0533ae: a web view that counts
        // characters overshot to the start of "😀😀😀\nA", and the after-context agreed with the piece only because the
        // emoji repeat).
        func afterFits(_ c: Int) -> Bool {
            let piece = b0.suffix(c)
            let shown = Array(piece.prefix { $0 != 10 })
            return shown.count < piece.count ? a1 == shown : WholeRead.agree(a1, shown, atEnd: false)
        }
        func fits(_ c: Int) -> Bool {
            WholeRead.agree(b1, Array(b0.prefix(b0.count - c)), atEnd: true) && afterFits(c)
        }
        fit = (WholeRead.agree(b1, Array(b0.prefix(b0.count - k)), atEnd: true), afterFits(k))
        // A web view moves by characters (run 4a2110a-150): the contexts fit the units k characters take. Refused,
        // never corrected (owner decision), also when both readings fit (text that repeats, such as one emoji over and
        // over: the walk cannot tell which host it is, code review). Either way the requested move is what the host
        // applied, and it undoes the same way.
        let chars = WholeRead.charUnits(b0, k)
        let byChars = chars.map { $0 != k && fits($0) } ?? false
        guard fits(k) else { return .failed(byChars ? "characters" : "badStep", moved: -k) }
        if byChars { return .failed("characters", moved: -k) }
        pieces.append(Array(b0.suffix(k)))
        count += k
        if count > cap { return .failed("tooLong", moved: -k) }
        return .moved(-k)
    }

    /// After `.retry`: the undo moved forward by one unit and must land where the probe started, which the
    /// after-context shows (the before-context may still be on its way). nil `moved`: neither move can be named then.
    public mutating func undone(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        guard changed, WholeRead.agree(a1, a0, atEnd: false), a1.isEmpty == a0.isEmpty else {
            return .failed("badUndo", moved: nil)
        }
        return .moved(1)
    }
}

/// One walk forward to the end of the field. `landed` changes nothing until a step fits, so a step that fit nothing
/// can be judged again on contexts read a moment later.
public struct ForwardWalk: Sendable {
    /// False ends a walk may undo and look at again (an after-context that showed empty mid-line: run 0f1bcd6-185).
    public static let maxRetries = 5
    public let cap: Int
    public private(set) var units: [UInt16] = []
    private var a0: [UInt16] = []
    /// The before-context the step was planned from: a probe at the end must show whether it moved at all.
    private var b0: [UInt16] = []
    private var k = 0
    /// The first step may count as a resync (the walk from the user's cursor only: the host can move the caret
    /// without telling the keyboard, run 163 web `mid` and `sel`).
    private let resyncFirst: Bool
    private var steps = 0
    public private(set) var resyncs = 0
    public private(set) var retries = 0
    /// The unit the last false end crossed: the undo must show it after the cursor again.
    private var crossed: UInt16?
    /// For the log after a step that fits nothing: did the before- and after-context fit the planned move?
    public private(set) var fit = (before: true, after: true)

    public init(cap: Int, resyncFirst: Bool = false) {
        self.cap = cap
        self.resyncFirst = resyncFirst
    }

    /// Units to move forward: a jump, or one unit over the line feed an empty after-context stops at. The first step
    /// of a walk that may resync is one unit: planned from a window that may be stale, a jump could be longer than the
    /// way to the end, and the host would cut it short while the record counted all of it (design review).
    public mutating func plan(before: [UInt16] = [], after: [UInt16]) -> Int {
        b0 = before
        a0 = after
        steps += 1
        if after.isEmpty {
            k = 1
        } else if resyncFirst, steps == 1 {
            // Never inside an emoji (code review): two units over a surrogate pair.
            k = after.count > 1 && WholeRead.isLow(after[1]) ? 2 : 1
        } else {
            k = WholeRead.safeJump(after, back: false)
        }
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if a0.isEmpty {
            guard changed else { return .done }
            // The after-context stops at a line feed, so the probe crossed one. A unit other than a line feed: the
            // after-context showed empty mid-line (a window on its way), a false end; undone and looked at again.
            fit = (b1.last == 10, true)
            guard b1.last == 10 else {
                if let r = resync() { return r }
                // The window grew in place (no move: the end; code review, round 2), or the probe crossed one unit the
                // after-context did not show (a false end). Both or neither: nothing this walk can name.
                let still = !b0.isEmpty && !b1.isEmpty && WholeRead.agree(b1, b0, atEnd: true)
                let over = !b0.isEmpty && !b1.isEmpty && WholeRead.agree(Array(b1.dropLast()), b0, atEnd: true)
                // Text after the cursor now (the host appended during the probe): no end (tower review of f0533ae).
                if still, !over, a1.isEmpty { return .done }
                guard over, !still, let x = b1.last else { return .failed("badStep", moved: nil) }
                guard retries < Self.maxRetries else { return .failed("falseEnd", moved: 1) }
                retries += 1
                crossed = x
                return .retry(-1)
            }
            units.append(10)
        } else {
            guard changed else { return .failed("stuck", moved: nil) }
            // The before-context window can be shorter than the piece: they agree where both have units.
            let piece = Array(a0.prefix(k))
            fit = (!b1.isEmpty && WholeRead.agree(b1, piece, atEnd: true), WholeRead.agree(a1, Array(a0.dropFirst(k)), atEnd: false))
            guard fit.before, fit.after else { return resync() ?? .failed("badStep", moved: k) }
            units += piece
        }
        if units.count > cap { return .failed("tooLong", moved: k) }
        return .moved(k)
    }

    /// After `.retry`: the undo moved back by one unit and must show the unit the probe crossed after the cursor again,
    /// and the before-context the probe started from. nil `moved`: neither move can be named then.
    public mutating func undone(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        guard changed, let x = crossed, a1.first == x, WholeRead.agree(b1, b0, atEnd: true) else {
            return .failed("badUndo", moved: nil)
        }
        crossed = nil
        return .moved(-1)
    }

    /// The first step of a walk from the user's cursor fit nothing: the contexts it planned from were stale. The host
    /// applied the one-unit move, so the position stays known (one unit off when the host already had the caret at
    /// the end: the contexts changed, the caret did not); the unit is not named, and the walk goes on from the
    /// contexts it shows now.
    private mutating func resync() -> WalkStep? {
        guard resyncFirst, steps == 1 else { return nil }
        resyncs += 1
        return .moved(k)
    }
}
