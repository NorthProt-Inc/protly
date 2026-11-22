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
    /// An empty before-context mid-field comes back within this long (probe run 153); only then is it probed.
    public static let emptyWait: TimeInterval = 0.3
    /// The poll interval; a step has settled when two polls in a row agree, at most `settlePolls` more polls.
    public static let poll: TimeInterval = 0.02
    public static let settlePolls = 5

    /// A step that may wait `wait` s still ends within `total`: the cap stops a read only between steps, so a step
    /// on its way always settles (Cancel's record, CursorReturn, never guesses about it).
    public static func canStart(elapsed: TimeInterval, wait: TimeInterval) -> Bool {
        elapsed + wait <= total
    }

    private static func isLow(_ x: UInt16) -> Bool { (0xDC00...0xDFFF).contains(x) }

    /// The step for a context `u` that ends (back) or starts (forward) at the cursor: the largest k < u.count that is
    /// not a period of `u` (so the move must change the context: the same context k units away would give `u` period
    /// k; run 7f2f443-135 got stuck on repeated sentences) and does not land the cursor before a low surrogate (run
    /// 3182f20-145 lost units on emoji). 1, or 2 when 1 would split a pair, below that.
    public static func safeJump(_ u: [UInt16], back: Bool) -> Int {
        let n = u.count
        guard n > 2 else { return n == 2 && back && isLow(u[1]) ? 2 : 1 }
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
    public static func refusal(back1: [UInt16], mid: [UInt16], back2: [UInt16], last: [UInt16]) -> String? {
        if back1 != back2 { return "disagree" }
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
    /// The walk stopped short. `moved`: the move the walk asked for (the host applies the requested offset; only the
    /// contexts were not as expected), nil when not even that is known.
    case failed(String, moved: Int?)
}

/// One walk back to the start. `plan` gives the next step, `landed` judges it from the contexts once it settled.
public struct BackWalk: Sendable {
    public let cap: Int
    /// The pieces moved over, nearest the end first.
    private var pieces: [[UInt16]] = []
    public private(set) var count = 0
    private var b0: [UInt16] = []
    private var a0: [UInt16] = []
    private var k = 0

    public init(cap: Int) { self.cap = cap }

    /// The units walked over, in field order.
    public var units: [UInt16] { pieces.reversed().flatMap { $0 } }

    /// Units to move back (always > 0). An empty before-context is probed with one unit (the driver waits
    /// `WholeRead.emptyWait` first for it to come back).
    public mutating func plan(before: [UInt16], after: [UInt16] = []) -> Int {
        b0 = before
        a0 = after
        k = before.isEmpty ? 1 : WholeRead.safeJump(before, back: true)
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if b0.isEmpty {
            guard changed else { return .done }
            // Text before the cursor although the context was empty, or a unit gained at the after-context's front:
            // the probe crossed text it cannot name (a false start mid-field; run 3293a10-138 put a guessed unit in).
            let gained = !a1.isEmpty && a1 != a0 && WholeRead.agree(Array(a1.dropFirst()), a0, atEnd: false)
            if !b1.isEmpty || gained { return .failed("falseStart", moved: -1) }
            return .phantom
        }
        guard changed else { return .failed("stuck", moved: 0) }
        func fits(_ c: Int) -> Bool {
            WholeRead.agree(b1, Array(b0.prefix(b0.count - c)), atEnd: true)
                && WholeRead.agree(a1, Array(b0.suffix(c).prefix { $0 != 10 }), atEnd: false)
        }
        guard fits(k) else {
            // A web view moves by characters (run 4a2110a-150): the contexts fit k plus the pairs crossed. Refused,
            // never corrected (owner decision). Either way the requested move is what the host applied, and it
            // undoes the same way.
            let pairs = b0.suffix(k).filter { (0xDC00...0xDFFF).contains($0) }.count
            if pairs > 0, k + pairs <= b0.count, fits(k + pairs) { return .failed("characters", moved: -k) }
            return .failed("badStep", moved: -k)
        }
        pieces.append(Array(b0.suffix(k)))
        count += k
        if count > cap { return .failed("tooLong", moved: -k) }
        return .moved(-k)
    }
}

/// One walk forward to the end of the field.
public struct ForwardWalk: Sendable {
    public let cap: Int
    public private(set) var units: [UInt16] = []
    private var a0: [UInt16] = []
    private var k = 0

    public init(cap: Int) { self.cap = cap }

    /// Units to move forward: a jump, or one unit over the line feed an empty after-context stops at.
    public mutating func plan(after: [UInt16]) -> Int {
        a0 = after
        k = after.isEmpty ? 1 : WholeRead.safeJump(after, back: false)
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if a0.isEmpty {
            guard changed else { return .done }
            // The after-context stops at a line feed, so the probe crossed one; any other change is not a move this
            // walk can name (a window that changed by itself, or a lagging context).
            guard b1.last == 10 else { return .failed("badStep", moved: 1) }
            units.append(10)
        } else {
            guard changed else { return .failed("stuck", moved: 0) }
            // The before-context window can be shorter than the piece: they agree where both have units.
            let piece = Array(a0.prefix(k))
            guard !b1.isEmpty, WholeRead.agree(b1, piece, atEnd: true),
                  WholeRead.agree(a1, Array(a0.dropFirst(k)), atEnd: false) else { return .failed("badStep", moved: k) }
            units += piece
        }
        if units.count > cap { return .failed("tooLong", moved: k) }
        return .moved(k)
    }
}
