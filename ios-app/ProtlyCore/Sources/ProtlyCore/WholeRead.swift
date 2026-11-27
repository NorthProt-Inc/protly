import Foundation

/// One-pass whole-field read: the proxy shows only a window around the cursor (diagnosis P1a: up to about 300 units
/// before the cursor, and after-context stops at every line feed), so the keyboard walks to the end (F), walks back to
/// the start (B1), returns to the end (R1), and probes +1 (FM). Any sign of lag, blank, misfit or timeout refuses at
/// once (no second look, no rejudge, no retry, no second pass).
///
/// The pure rules live here; FieldText.swift drives them on the text document proxy.
public enum WholeRead {
    /// The longest whole read, in seconds (the one cap; set to 6 s so a 335-unit mid-text draft fits with `canStart`'s
    /// `moveWait` before R1, pending phone measurements). The keys wait meanwhile.
    public static let total: TimeInterval = 6
    /// The strip says the read is still going after this long.
    public static let progressAfter: TimeInterval = 2
    /// How long a move may take to show in the contexts.
    public static let moveWait: TimeInterval = 1
    /// A probe step (one unit past an empty context): no change for this long is the end or the start.
    public static let probeWait: TimeInterval = 0.5
    /// A step whose change takes longer than this marks the host slow: any silent probe after it cannot be trusted as
    /// the start or end, so the read is marked unclean and refused (same threshold as K1b's slow-step flag).
    public static let lateStep: TimeInterval = 0.2
    /// An empty before-context waits this long once before probing -1.
    public static let emptyWait: TimeInterval = 0.3
    /// The poll interval; a step has settled when two polls in a row agree, at most `settlePolls` more polls.
    public static let poll: TimeInterval = 0.02
    public static let settlePolls = 5

    /// A changed step that took longer than `lateStep` is late (the host lagged).
    public static func isLate(elapsed: TimeInterval) -> Bool { elapsed > lateStep }

    /// How long after a synchronous Replace, Undo or Insert the host may still be applying the edits: no new field
    /// read starts and host callbacks count as the write's own echo until this passes.
    public static func replaceSettle(deletes: Int, inserted: Int) -> TimeInterval {
        1.5 + 0.004 * Double(deletes) + 0.0025 * Double(inserted)
    }

    /// A step that may wait `wait` s still ends within `total`: the cap stops a read only between steps, so a step
    /// on its way always settles (Cancel's record, CursorReturn, never guesses about it).
    public static func canStart(elapsed: TimeInterval, wait: TimeInterval) -> Bool {
        elapsed + wait <= total
    }

    static func isLow(_ x: UInt16) -> Bool { (0xDC00...0xDFFF).contains(x) }

    static func hasPair(_ u: [UInt16]) -> Bool { u.contains(where: isLow) }

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

    /// The UTF-16 units the first `k` characters of `u` take (a surrogate pair is one); nil when `u` holds fewer.
    static func charUnitsFront(_ u: [UInt16], _ k: Int) -> Int? {
        var i = 0
        for _ in 0..<k {
            guard i < u.count else { return nil }
            i += 1
            if i < u.count, isLow(u[i]), (0xD800...0xDBFF).contains(u[i - 1]) { i += 1 }
        }
        return i
    }

    /// The step for a context `u` that ends (back) or starts (forward) at the cursor: the largest k < u.count that is
    /// not a period of `u` (so the move must change the context) and does not land the cursor before a low surrogate.
    /// When `u` holds a surrogate pair, leaves at least 3 units of overlap under both the units and the characters
    /// readings so a characters host cannot clamp past the window undetected. 1, or 2 when 1 would split a pair, below.
    public static func safeJump(_ u: [UInt16], back: Bool) -> Int {
        let n = u.count
        // One unit lands at index 1 either way: never there when it is a pair's low half (Codex bug 3: a forward step
        // over a lone emoji split it).
        guard n > 2 else { return n == 2 && isLow(u[1]) ? 2 : 1 }
        let paired = hasPair(u)
        var k = n - (paired ? 3 : 1)
        while k > 1 {
            let charsOK = !paired || ((back ? charUnits(u, k) : charUnitsFront(u, k)).map { n - $0 >= 3 } ?? false)
            if charsOK, !isLow(u[back ? n - k : k]) {
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

    /// What one walk of a one-pass read produced.
    public enum WalkOutcome: Equatable, Sendable {
        case done([UInt16])
        case failed(String)
    }

    /// What R1 (one move forward by B1's length) produced.
    public enum ReturnOutcome: Equatable, Sendable {
        case atEnd
        case notAtEnd
        case timeUp
    }

    /// Evidence gathered by the keyboard for a one-pass whole-field read (F, B1, R1, FM).
    public struct OnePass: Equatable, Sendable {
        public var first: WalkOutcome
        public var back: WalkOutcome?
        public var fromSelection: Bool
        public var hasText: Bool
        public var returned: ReturnOutcome?
        public var endProbe: WalkOutcome?
        public var clean: Bool

        public init(first: WalkOutcome, back: WalkOutcome? = nil, fromSelection: Bool = false, hasText: Bool = false,
                    returned: ReturnOutcome? = nil, endProbe: WalkOutcome? = nil, clean: Bool = true) {
            self.first = first
            self.back = back
            self.fromSelection = fromSelection
            self.hasText = hasText
            self.returned = returned
            self.endProbe = endProbe
            self.clean = clean
        }
    }

    /// The pure verdict on a one-pass read.
    public enum ReadVerdict: Equatable, Sendable {
        case accept([UInt16])
        case empty
        case refuse(String)
    }

    /// R1 landed at the field's end: the move changed the contexts, nothing follows the cursor, and the before-context
    /// agrees with the end's.
    public static func showsEnd(changed: Bool, before: [UInt16], after: [UInt16], endBefore: [UInt16]) -> Bool {
        changed && after.isEmpty && !before.isEmpty && agreeAtEnd(before, endBefore)
    }

    /// Pure acceptance rule for a one-pass whole-field read: F reached the end, a collapsed selection crossed nothing
    /// (Codex bug 2), B1 reached the start, R1 showed the end again, FM crossed nothing, B1 ends with what F crossed,
    /// and every step was clean (no late, blank, undone or misfit step). Anything else is refused at once.
    public static func accept(_ r: OnePass) -> ReadVerdict {
        guard r.clean else { return .refuse("unclean") }
        let first: [UInt16]
        switch r.first {
        case .done(let u): first = u
        case .failed(let why): return .refuse("f:\(why)")
        }
        if r.fromSelection, !first.isEmpty { return .refuse("partialSelection") }
        let back: [UInt16]
        switch r.back {
        case .done(let u): back = u
        case .failed(let why): return .refuse("b1:\(why)")
        case nil: return .refuse("b1:missing")
        }
        if back.isEmpty, first.isEmpty {
            return r.hasText ? .refuse("emptyHasText") : .empty
        }
        switch r.returned {
        case .atEnd: break
        case .timeUp: return .refuse("r1:timeUp")
        case .notAtEnd, nil: return .refuse("r1:notAtEnd")
        }
        let mid: [UInt16]
        switch r.endProbe {
        case .done(let u): mid = u
        case .failed(let why): return .refuse("fm:\(why)")
        case nil: return .refuse("fm:missing")
        }
        guard mid.isEmpty else { return .refuse("fm:crossed") }
        guard hasSuffix(back, first) else { return .refuse("firstEnd") }
        if String(decoding: back, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        return .accept(back)
    }
}

/// What one step of a walk found.
public enum WalkStep: Equatable, Sendable {
    /// The step fits the contexts: the cursor moved by this many UTF-16 units.
    case moved(Int)
    /// The walk reached its end (forward) or the start (back).
    case done
    /// The walk stopped short. `moved`: the move the host applied, nil when it cannot be named.
    case failed(String, moved: Int?)
}

/// One walk back to the start. `plan` gives the next step, `landed` judges it from the contexts once it settled.
public struct BackWalk: Sendable {
    /// The pieces moved over, nearest the end first.
    private var pieces: [[UInt16]] = []
    private var b0: [UInt16] = []
    private var a0: [UInt16] = []
    private var k = 0
    /// For the log after a step that fits nothing: did the before- and after-context fit the planned move?
    public private(set) var fit = (before: true, after: true)

    public init() {}

    /// The units walked over, in field order.
    public var units: [UInt16] { pieces.reversed().flatMap { $0 } }

    /// Units to move back (always > 0). An empty before-context is probed with one unit (the driver waits
    /// `WholeRead.emptyWait` once first).
    public mutating func plan(before: [UInt16], after: [UInt16] = []) -> Int {
        b0 = before
        a0 = after
        k = before.isEmpty ? 1 : WholeRead.safeJump(before, back: true)
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if b0.isEmpty {
            guard changed else { return .done }
            let gained = !a1.isEmpty && a1 != a0 && WholeRead.agree(Array(a1.dropFirst()), a0, atEnd: false)
            if !b1.isEmpty || gained { return .failed("falseStart", moved: -1) }
            return .failed("phantom", moved: nil)
        }
        guard changed else { return .failed("stuck", moved: nil) }
        // A clamped pair move on a characters host cannot be reversed from k; report moved: nil so restore never overshoots.
        let failMoved: Int? = WholeRead.hasPair(b0) && b1.isEmpty ? nil : -k
        // A jump shorter than the context always leaves text before the cursor; an empty before-context refuses at once.
        guard !b1.isEmpty || k >= b0.count else {
            fit = (false, a1.isEmpty)
            return .failed("badStep", moved: failMoved)
        }
        func afterFits(_ c: Int) -> Bool {
            let piece = b0.suffix(c)
            let shown = Array(piece.prefix { $0 != 10 })
            if !shown.isEmpty, a1.isEmpty { return false }
            return WholeRead.agree(a1, shown, atEnd: false) && (shown.count == piece.count || a1.count <= shown.count)
        }
        func fits(_ c: Int) -> Bool {
            WholeRead.agree(b1, Array(b0.prefix(b0.count - c)), atEnd: true) && afterFits(c)
        }
        func fitsChars(_ c: Int) -> Bool {
            guard fits(c) else { return false }
            let pre = b0.prefix(b0.count - c)
            let shown = b0.suffix(c).prefix { $0 != 10 }
            return (!pre.isEmpty && !b1.isEmpty) || (!shown.isEmpty && !a1.isEmpty)
        }
        fit = (WholeRead.agree(b1, Array(b0.prefix(b0.count - k)), atEnd: true), afterFits(k))
        // A web view moves by characters: refused, never corrected, also when both readings fit with non-vacuous evidence.
        let chars = WholeRead.charUnits(b0, k)
        let byChars = chars.map { $0 != k && fitsChars($0) } ?? false
        guard fits(k) else { return .failed(byChars ? "characters" : "badStep", moved: failMoved) }
        if byChars { return .failed("characters", moved: failMoved) }
        pieces.append(Array(b0.suffix(k)))
        return .moved(-k)
    }
}

/// One walk forward to the end of the field.
public struct ForwardWalk: Sendable {
    public private(set) var units: [UInt16] = []
    private var a0: [UInt16] = []
    private var b0: [UInt16] = []
    private var k = 0
    /// For the log after a step that fits nothing: did the before- and after-context fit the planned move?
    public private(set) var fit = (before: true, after: true)

    public init() {}

    /// Units to move forward: a jump, or one unit over the line feed an empty after-context stops at.
    public mutating func plan(before: [UInt16] = [], after: [UInt16]) -> Int {
        b0 = before
        a0 = after
        k = after.isEmpty ? 1 : WholeRead.safeJump(after, back: false)
        return k
    }

    public mutating func landed(changed: Bool, before b1: [UInt16], after a1: [UInt16]) -> WalkStep {
        if a0.isEmpty {
            guard changed else { return .done }
            fit = (b1.last == 10, true)
            guard b1.last == 10 else {
                // Window grew in place at the real end (no move) vs crossed an unnamed non-LF unit (false end).
                let still = !b0.isEmpty && !b1.isEmpty && WholeRead.agree(b1, b0, atEnd: true)
                let over = !b0.isEmpty && !b1.isEmpty && WholeRead.agree(Array(b1.dropLast()), b0, atEnd: true)
                if still, !over, a1.isEmpty { return .done }
                if over, !still { return .failed("falseEnd", moved: 1) }
                return .failed("badStep", moved: nil)
            }
            units.append(10)
        } else {
            guard changed else { return .failed("stuck", moved: nil) }
            let piece = Array(a0.prefix(k))
            let rest = Array(a0.dropFirst(k))
            fit = (!b1.isEmpty && WholeRead.agree(b1, piece, atEnd: true),
                   (rest.isEmpty || !a1.isEmpty) && WholeRead.agree(a1, rest, atEnd: false))
            func fitsChars(_ c: Int) -> Bool {
                let p = Array(a0.prefix(c)), r = Array(a0.dropFirst(c))
                return !b1.isEmpty && WholeRead.agree(b1, p, atEnd: true)
                    && (r.isEmpty || !a1.isEmpty) && a1.count <= r.count && WholeRead.agree(a1, r, atEnd: false)
            }
            let chars = WholeRead.charUnitsFront(a0, k)
            let byChars = chars.map { $0 != k && fitsChars($0) } ?? false
            let failMoved: Int? = WholeRead.hasPair(a0) && a1.isEmpty ? nil : k
            guard fit.before, fit.after else { return .failed(byChars ? "characters" : "badStep", moved: failMoved) }
            if byChars { return .failed("characters", moved: failMoved) }
            units += piece
        }
        return .moved(k)
    }
}
