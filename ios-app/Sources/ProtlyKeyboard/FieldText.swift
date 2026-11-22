import ProtlyCore
import UIKit
import os

/// Reads and replaces the whole field through the text document proxy.
/// The proxy only shows text around the cursor, so the cursor goes to the end first.
@MainActor
enum FieldText {
    /// diag/p1-phone-read probe: lengths, line-break counts and timings only, never text.
    static let probe = Logger(subsystem: "com.northprot.protly", category: "read")

    /// "utf16/lf" plus "/cr../ps../ls.." when a host uses another line break; "nil" for no context.
    static func shape(_ s: String?) -> String {
        guard let s else { return "nil" }
        var lf = 0, cr = 0, ps = 0, ls = 0
        for u in s.utf16 {
            switch u {
            case 10: lf += 1
            case 13: cr += 1
            case 0x2029: ps += 1
            case 0x2028: ls += 1
            default: break
            }
        }
        return "\(s.utf16.count)/\(lf)" + (cr + ps + ls > 0 ? "/cr\(cr)ps\(ps)ls\(ls)" : "")
    }

    /// One cursor step of a read, for Cancel (CursorReturn): sent to the host, then shown by it (with the
    /// before-context it shows now) or given up on.
    enum Move {
        case sending(String)
        case applied(before: String)
        case notApplied
    }

    /// The field text, or the selection when there is one. nil when the field is empty or the read was cancelled.
    /// `record` gets each cursor step as it is sent and then whether the host showed it. A cancel stops the read
    /// before its next step, never during one: a step on its way is always settled first, so Cancel moves back only
    /// over steps that landed (CursorReturn). The whole read ends within 2 s (FieldReadBudget, D-B): the keys wait
    /// meanwhile. The cap, like a cancel, only stops the read before a step; text left after the cursor then makes it
    /// a cut-short read.
    static func read(_ proxy: UITextDocumentProxy, record: (Move) -> Void) async -> (text: String, isSelection: Bool)? {
        // diag/p1-walk-back: on this branch every read is the walk probe below (both ends found by moving).
        if walkProbe { return await walkRead(proxy) }
        let t0 = ProcessInfo.processInfo.systemUptime
        func ms() -> Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }
        let startShape = "before=\(shape(proxy.documentContextBeforeInput)) after=\(shape(proxy.documentContextAfterInput)) sel=\(shape(proxy.selectedText))"
        probe.debug("read start \(startShape, privacy: .public)")
        if let sel = proxy.selectedText, !sel.isEmpty {
            let selShape = shape(sel)
            probe.debug("read end reason=selection returned=\(selShape, privacy: .public)")
            return (sel, true)
        }
        let budget = FieldReadBudget(start: ProcessInfo.processInfo.systemUptime)
        var reason = "max-steps"
        var steps = 0
        // The after-context often stops at a paragraph break, so one jump can land mid-text: repeat.
        for _ in 0..<FieldReadBudget.maxSteps {
            guard !Task.isCancelled else { return nil }  // cancelled before a move: never start one
            // The step's full wait no longer fits in the cap: stop here, the keys come back.
            guard budget.canStartStep(now: ProcessInfo.processInfo.systemUptime) else { reason = "budget"; break }
            guard let after = proxy.documentContextAfterInput, !after.isEmpty else { reason = "no-after"; break }
            let before = proxy.documentContextBeforeInput
            steps += 1
            let stepLine = "read step=\(steps) t=\(ms()) send=\(after.utf16.count) before=\(shape(before)) after=\(shape(after))"
            probe.debug("\(stepLine, privacy: .public)")
            record(.sending(after))
            proxy.adjustTextPosition(byCharacterOffset: after.utf16.count)  // UTF-16 units
            let sent = ProcessInfo.processInfo.systemUptime
            // Hosts apply the move asynchronously: poll until the context changes (max 1 s). Either side counts: the
            // next chunk can read the same as this one (blank lines, a repeated line), the text before never does.
            // The wait ignores a cancel and the cap: the step settles first, then the loop stops before the next one.
            var moved = false
            var polls = 0
            while budget.isWaiting(sentAt: sent, now: ProcessInfo.processInfo.systemUptime) {
                await pause()
                polls += 1
                let a1 = proxy.documentContextAfterInput, b1 = proxy.documentContextBeforeInput
                if a1 != after || b1 != before {
                    moved = true
                    let which = (a1 != after ? "A" : "") + (b1 != before ? "B" : "")
                    let movedLine = "read moved step=\(steps) t=\(ms()) polls=\(polls) changed=\(which) before=\(shape(b1)) after=\(shape(a1))"
                    probe.debug("\(movedLine, privacy: .public)")
                    break
                }
            }
            guard moved else {
                let notLine = "read notApplied step=\(steps) t=\(ms()) polls=\(polls)"
                probe.debug("\(notLine, privacy: .public)")
                record(.notApplied)
                reason = "not-applied"
                break  // the host never reported the move: never issue it again
            }
            record(.applied(before: proxy.documentContextBeforeInput ?? ""))
        }
        guard !Task.isCancelled else { return nil }
        let endLine = "read end reason=\(reason) steps=\(steps) t=\(ms()) before=\(shape(proxy.documentContextBeforeInput)) after=\(shape(proxy.documentContextAfterInput))"
        probe.debug("\(endLine, privacy: .public)")
        // Probe 3: only on the skip drafts (each paragraph ends with a pilcrow), and only when the loop stopped on
        // an empty after-context. Logs, then puts the cursor back where the loop left it.
        if reason == "no-after", (proxy.documentContextBeforeInput ?? "").hasSuffix("\u{00B6}") {
            await skipProbe(proxy, t0: t0)
        }
        // A whitespace-only field counts as empty, as in the bar: the protly key reads the clipboard.
        guard let before = proxy.documentContextBeforeInput,
              !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (before, false)
    }

    /// diag/p1-phone-read probe 3: does one-unit step past an empty after-context cross a line break (the next
    /// paragraph then shows after the cursor) or change nothing (the end of the field)? At most 3 steps, each waited
    /// for up to 0.5 s; then the cursor moves back over the steps that landed. Lengths only.
    private static func skipProbe(_ proxy: UITextDocumentProxy, t0: TimeInterval) async {
        func ms() -> Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }
        func settle(_ b0: String?, _ a0: String?) async -> (moved: Bool, polls: Int) {
            let sent = ProcessInfo.processInfo.systemUptime
            var polls = 0
            while ProcessInfo.processInfo.systemUptime - sent < 0.5 {
                await pause()
                polls += 1
                if proxy.documentContextBeforeInput != b0 || proxy.documentContextAfterInput != a0 { return (true, polls) }
            }
            return (false, polls)
        }
        var landed = 0
        for k in 1...3 {
            let b0 = proxy.documentContextBeforeInput, a0 = proxy.documentContextAfterInput
            proxy.adjustTextPosition(byCharacterOffset: 1)
            let r = await settle(b0, a0)
            let line = "skip k=\(k) t=\(ms()) moved=\(r.moved ? 1 : 0) polls=\(r.polls) before=\(shape(proxy.documentContextBeforeInput)) after=\(shape(proxy.documentContextAfterInput))"
            probe.debug("\(line, privacy: .public)")
            guard r.moved else { break }
            landed += 1
            if let a = proxy.documentContextAfterInput, !a.isEmpty { break }  // the next paragraph shows
        }
        guard landed > 0 else { return }
        let b0 = proxy.documentContextBeforeInput, a0 = proxy.documentContextAfterInput
        proxy.adjustTextPosition(byCharacterOffset: -landed)
        let r = await settle(b0, a0)
        let back = "skip back=\(landed) t=\(ms()) moved=\(r.moved ? 1 : 0) polls=\(r.polls) before=\(shape(proxy.documentContextBeforeInput)) after=\(shape(proxy.documentContextAfterInput))"
        probe.debug("\(back, privacy: .public)")
    }

    /// 20 ms that a cancel does not cut short (Task.sleep would end at once).
    private static func pause() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { c.resume() }
        }
    }

    // MARK: diag/p1-walk-back: both ends of the field found by moving the cursor

    /// On: every read is `walkRead`. A computed property, so the shipping read below it still compiles as it was.
    static var walkProbe: Bool { true }

    /// FNV-1a (32 bit) over UTF-16 units, 8 hex digits. WalkChecks.swift and read-probe.html hash the host's text the
    /// same way, so a walked text is compared with the field without logging either.
    nonisolated static func fnv(_ s: String) -> String { fnvUnits(Array(s.utf16)) }

    nonisolated static func fnvUnits(_ u: [UInt16]) -> String {
        var h: UInt32 = 0x811C_9DC5
        for x in u {
            h ^= UInt32(x)
            h = h &* 0x0100_0193
        }
        return String(format: "%08x", h)
    }

    /// The three contexts at one moment.
    private struct Ctx: Equatable {
        let b: String?
        let a: String?
        let s: String?
    }

    enum WalkPolicy: String {
        /// Back by the whole before-context.
        case jump
        /// Back by the before-context less one unit: never a move between two places whose windows read the same.
        case jump1
        /// Back one UTF-16 unit at a time.
        case unit
    }

    /// One walk: the text moved over (field order), why it stopped, its steps and time.
    struct WalkResult {
        var units: [UInt16] = []
        var reason = "none"
        var steps = 0
        var ms = 0

        var summary: String {
            "\(units.count)/\(units.filter { $0 == 10 }.count)/h\(FieldText.fnvUnits(units))/\(reason)"
        }
    }

    /// Select-all calls so far: the collapse move rotates +1, -1, 0.
    static var selCalls = 0
    /// Unit walks longer than `unitShortCap` steps so far: only the first one in this keyboard process may run on
    /// (up to 6000 steps, 200 s), the later ones stop at the cap.
    static var longUnitWalks = 0
    static let unitShortCap = 1700

    private static func ctx(_ p: UITextDocumentProxy) -> Ctx {
        Ctx(b: p.documentContextBeforeInput, a: p.documentContextAfterInput, s: p.selectedText)
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func walkLog(_ line: String) {
        probe.debug("\(line, privacy: .public)")
    }

    private static func units(_ s: String?) -> [UInt16] { Array((s ?? "").utf16) }

    /// `a` and `b` agree where both have text: the shorter is the longer's prefix (or suffix).
    private static func agree(_ a: [UInt16], _ b: [UInt16], atEnd: Bool) -> Bool {
        let n = min(a.count, b.count)
        return atEnd ? Array(a.suffix(n)) == Array(b.suffix(n)) : Array(a.prefix(n)) == Array(b.prefix(n))
    }

    /// One cursor move, then a poll every 20 ms until any context changes or `limit` s pass. `settle`: one more poll
    /// after the change, which says whether the host's update came in two parts (`late`) and reads the later one.
    private static func step(_ p: UITextDocumentProxy, by k: Int, limit: TimeInterval, settle: Bool)
        async -> (changed: Bool, polls: Int, ms: Int, late: Bool, c: Ctx) {
        let c0 = ctx(p)
        let sent = uptime()
        p.adjustTextPosition(byCharacterOffset: k)
        var polls = 0
        while uptime() - sent < limit {
            await pause()
            polls += 1
            let c1 = ctx(p)
            if c1 != c0 {
                let ms = Int((uptime() - sent) * 1000)
                guard settle else { return (true, polls, ms, false, c1) }
                // diag/p1-walk-back-unit: settle until two polls in a row read the same (up to 5 more polls). Run
                // 7f2f443-135: unit steps read without a settle gave right lengths but other texts.
                var prev = c1
                var late = false
                for _ in 0..<5 {
                    await pause()
                    let c2 = ctx(p)
                    if c2 == prev { break }
                    late = true
                    prev = c2
                }
                return (true, polls, ms, late, prev)
            }
        }
        // A last look: a stalled main thread can end the loop between two polls, never call that "no change".
        let last = ctx(p)
        return (last != c0, polls, Int((uptime() - sent) * 1000), false, last)
    }

    /// Walks the cursor back from where it is until a step at an empty before-context changes nothing for 0.5 s (the
    /// start), a step changes nothing for 1 s although the before-context had text (`stuck`), or a cap. Each piece
    /// moved over is the end of the before-context the step started from. Lengths, counts and hashes only.
    private static func walkBack(_ p: UITextDocumentProxy, _ policy: WalkPolicy, maxSteps: Int,
                                 timeCap: TimeInterval) async -> WalkResult {
        var r = WalkResult()
        var pieces: [[UInt16]] = []  // nearest first
        let start = uptime()
        var polls1 = 0, polls2 = 0, pollsMore = 0, maxPolls = 0, maxMs = 0
        var grew = 0, shrank = 0, maxFront = 0, minFront = 0, incons = 0, afterBad = 0, lfSteps = 0
        var falseStarts = 0, late = 0, nilBefore = 0
        let p0 = ctx(p)
        walkLog("wb \(policy.rawValue) begin before=\(shape(p0.b)) after=\(shape(p0.a)) hb=\(fnv(p0.b ?? ""))")
        while true {
            if Task.isCancelled { r.reason = "cancelled"; break }
            if r.steps >= maxSteps { r.reason = "step-cap"; break }
            if uptime() - start > timeCap { r.reason = "time-cap"; break }
            let c0 = ctx(p)
            let b0 = units(c0.b)
            let probing = b0.isEmpty
            let k: Int
            if probing {
                k = 1
            } else {
                switch policy {
                case .jump: k = b0.count
                case .jump1: k = max(1, b0.count - 1)
                case .unit: k = 1
                }
            }
            r.steps += 1
            let s = await step(p, by: -k, limit: probing ? 0.5 : 1.0, settle: true)  // diag/p1-walk-back-unit: unit too
            maxPolls = max(maxPolls, s.polls)
            guard s.changed else {
                r.reason = probing ? "start" : "stuck"
                walkLog("wb \(policy.rawValue) \(r.reason) s=\(r.steps) k=\(k) polls=\(s.polls) ms=\(s.ms) before=\(shape(s.c.b)) after=\(shape(s.c.a))")
                break
            }
            maxMs = max(maxMs, s.ms)
            switch s.polls {
            case 1: polls1 += 1
            case 2: polls2 += 1
            default: pollsMore += 1
            }
            if s.late { late += 1 }
            if s.c.b == nil { nilBefore += 1 }
            let b1 = units(s.c.b), a1 = units(s.c.a)
            let piece: [UInt16]
            var front = 0
            var cons = true
            if probing {
                // The before-context was empty, yet the step moved: text remained (a false start). The unit moved over
                // is the after-context's first; an empty after-context means a line feed (it stops there).
                falseStarts += 1
                piece = a1.isEmpty ? [10] : Array(a1.prefix(1))
            } else {
                piece = Array(b0.suffix(k))
                let kept = Array(b0.prefix(b0.count - k))
                // The new before-context ends with what the old one kept, with more (or less) in front of it.
                cons = agree(b1, kept, atEnd: true)
                front = b1.count - kept.count
                if !cons {
                    incons += 1
                } else if front > 0 {
                    grew += 1
                } else if front < 0 {
                    shrank += 1
                }
                maxFront = max(maxFront, front)
                minFront = min(minFront, front)
            }
            // The new after-context starts with the piece up to its first line feed (the after-context stops there).
            let head = Array(piece.prefix { $0 != 10 })
            let aok = agree(a1, head, atEnd: false)
            if !aok { afterBad += 1 }
            let lf = piece.filter { $0 == 10 }.count
            if lf > 0 { lfSteps += 1 }
            pieces.append(piece)
            let notable = policy != .unit || probing || !cons || !aok || s.polls > 2 || lf > 0 || r.steps % 100 == 0
            if notable {
                walkLog("wb \(policy.rawValue) s=\(r.steps) k=\(k) polls=\(s.polls) ms=\(s.ms) late=\(s.late ? 1 : 0) front=\(front) cons=\(cons ? 1 : 0) aok=\(aok ? 1 : 0) lf=\(lf) fs=\(probing ? 1 : 0) before=\(shape(s.c.b)) after=\(shape(s.c.a))")
            }
        }
        r.units = pieces.reversed().flatMap { $0 }
        r.ms = Int((uptime() - start) * 1000)
        walkLog("wb \(policy.rawValue) done \(r.summary) steps=\(r.steps) ms=\(r.ms) polls=\(polls1),\(polls2),\(pollsMore) maxpolls=\(maxPolls) maxms=\(maxMs) grew=\(grew) shrank=\(shrank) front=\(minFront)..\(maxFront) incons=\(incons) afterbad=\(afterBad) lfsteps=\(lfSteps) falsestarts=\(falseStarts) late=\(late) nilbefore=\(nilBefore)")
        return r
    }

    /// Forward by what `w` walked back, in one move: is the cursor back where the walk began (`r1`: both contexts as
    /// at the base; `rs`: the before-context is at least the walked text's end; `rx`: neither; `r-`: nothing walked).
    private static func walkReturn(_ p: UITextDocumentProxy, _ w: WalkResult, base: Ctx, tag: String) async -> String {
        let k = w.units.count
        guard k > 0 else { return "r-" }
        let s = await step(p, by: k, limit: 1.0, settle: true)
        let b = units(s.c.b)
        let same = (s.c.b ?? "") == (base.b ?? "") && (s.c.a ?? "") == (base.a ?? "")
        let suf = !b.isEmpty && w.units.count >= b.count && Array(w.units.suffix(b.count)) == b
        let code = same ? "r1" : (suf ? "rs" : "rx")
        walkLog("wr \(tag) k=\(k) ch=\(s.changed ? 1 : 0) polls=\(s.polls) ms=\(s.ms) late=\(s.late ? 1 : 0) \(code) before=\(shape(s.c.b)) after=\(shape(s.c.a)) hb=\(fnvUnits(b)) base=\(shape(base.b))/\(shape(base.a))")
        return code
    }

    /// Walks forward to the end: by the after-context less one unit, or one unit when it is empty (over a line feed,
    /// which the after-context stops at); the end is a one-unit step that changes nothing for 0.5 s.
    private static func walkForward(_ p: UITextDocumentProxy, maxSteps: Int, tag: String) async -> WalkResult {
        var r = WalkResult()
        var pieces: [UInt16] = []
        let start = uptime()
        var bad = 0
        while true {
            if Task.isCancelled { r.reason = "cancelled"; break }
            if r.steps >= maxSteps { r.reason = "step-cap"; break }
            let a0 = units(ctx(p).a)
            let probing = a0.isEmpty
            let k = probing ? 1 : max(1, a0.count - 1)
            r.steps += 1
            let s = await step(p, by: k, limit: probing ? 0.5 : 1.0, settle: true)
            guard s.changed else {
                r.reason = probing ? "end" : "stuck"
                walkLog("wf \(tag) \(r.reason) s=\(r.steps) k=\(k) polls=\(s.polls) ms=\(s.ms) before=\(shape(s.c.b)) after=\(shape(s.c.a))")
                break
            }
            let b1 = units(s.c.b)
            let piece: [UInt16] = probing ? Array(b1.suffix(1)) : Array(a0.prefix(k))
            let bok = !piece.isEmpty && b1.count >= piece.count && Array(b1.suffix(piece.count)) == piece
            if !bok { bad += 1 }
            pieces += piece
            walkLog("wf \(tag) s=\(r.steps) k=\(k) skip=\(probing ? 1 : 0) polls=\(s.polls) ms=\(s.ms) late=\(s.late ? 1 : 0) bok=\(bok ? 1 : 0) lf=\(piece.filter { $0 == 10 }.count) before=\(shape(s.c.b)) after=\(shape(s.c.a))")
        }
        r.units = pieces
        r.ms = Int((uptime() - start) * 1000)
        walkLog("wf \(tag) done \(r.summary) steps=\(r.steps) ms=\(r.ms) bad=\(bad)")
        return r
    }

    /// The probe read. A selection is collapsed first (+1, -1 or 0, in turn). From that base: the unit walk back
    /// (the text before the cursor) and one move forward again, then the walk forward to the end (the text after it).
    /// Then from the end, which a walk forward always finds again: the jump walk back, one move forward, a walk to
    /// the end; the same with jump1. A step that changes nothing although text remained may still have moved the
    /// cursor, so each jump walk starts from the end. Returns the first whole text found (unit plus forward, jump1,
    /// jump) with the cursor at the end. The numbers go to the log and, through WalkNote, into the CI stub's reply.
    static func walkRead(_ p: UITextDocumentProxy) async -> (text: String, isSelection: Bool)? {
        let t0 = uptime()
        let c0 = ctx(p)
        walkLog("walk start before=\(shape(c0.b)) after=\(shape(c0.a)) sel=\(shape(c0.s)) hb=\(fnv(c0.b ?? "")) ha=\(fnv(c0.a ?? "")) hs=\(fnv(c0.s ?? ""))")
        var note: [String] = []
        if let sel = c0.s, !sel.isEmpty {
            let v = [1, -1, 0][selCalls % 3]
            selCalls += 1
            var tries = [v]
            if v != 1 { tries.append(1) }  // still selected after the first move: +1
            for (i, move) in tries.enumerated() {
                if i > 0, (ctx(p).s ?? "").isEmpty { break }
                let s = await step(p, by: move, limit: 1.0, settle: true)
                walkLog("walk collapse v=\(move) try=\(i + 1) ch=\(s.changed ? 1 : 0) polls=\(s.polls) ms=\(s.ms) late=\(s.late ? 1 : 0) before=\(shape(s.c.b)) after=\(shape(s.c.a)) sel=\(shape(s.c.s)) hb=\(fnv(s.c.b ?? "")) ha=\(fnv(s.c.a ?? ""))")
                note.append("c\(move)=\(s.changed ? 1 : 0)/b\((s.c.b ?? "").utf16.count)/a\((s.c.a ?? "").utf16.count)/s\((s.c.s ?? "").utf16.count)")
            }
        }
        let base = ctx(p)
        walkLog("walk base before=\(shape(base.b)) after=\(shape(base.a)) sel=\(shape(base.s))")
        let cap = longUnitWalks == 0 ? 6000 : unitShortCap
        let unit = await walkBack(p, .unit, maxSteps: cap, timeCap: 200)
        if unit.steps > unitShortCap { longUnitWalks += 1 }
        let unitBack = await walkReturn(p, unit, base: base, tag: "unit")
        let forward = await walkForward(p, maxSteps: 400, tag: "f")
        let end = ctx(p)
        let jump = await walkBack(p, .jump, maxSteps: 400, timeCap: 60)
        let jumpBack = await walkReturn(p, jump, base: end, tag: "jump")
        let jumpEnd = await walkForward(p, maxSteps: 400, tag: "fj")
        let jump1 = await walkBack(p, .jump1, maxSteps: 400, timeCap: 60)
        let jump1Back = await walkReturn(p, jump1, base: end, tag: "jump1")
        let jump1End = await walkForward(p, maxSteps: 400, tag: "fj1")
        let landed = ["r1", "r-"]
        var found: [(String, [UInt16])] = []
        if unit.reason == "start", landed.contains(unitBack), forward.reason == "end" {
            found.append(("unit", unit.units + forward.units))
        }
        if jump1.reason == "start", landed.contains(jump1Back) { found.append(("jump1", jump1.units)) }
        if jump.reason == "start", landed.contains(jumpBack) { found.append(("jump", jump.units)) }
        let pick = found.first?.0 ?? "none"
        let whole = found.first?.1 ?? (unit.units + forward.units)
        let agreeAll = found.allSatisfy { $0.1 == whole } ? 1 : 0
        let ms = Int((uptime() - t0) * 1000)
        walkLog("walk whole \(whole.count)/\(whole.filter { $0 == 10 }.count)/h\(fnvUnits(whole)) pick=\(pick) found=\(found.count) agree=\(agreeAll) ms=\(ms) after=\(shape(p.documentContextAfterInput))")
        note += ["u=\(unit.summary)/\(unitBack)/\(unit.ms)ms", "f=\(forward.summary)/\(forward.ms)ms",
                 "j=\(jump.summary)/\(jumpBack)/\(jump.ms)ms", "fj=\(jumpEnd.units.count)/\(jumpEnd.reason)",
                 "j1=\(jump1.summary)/\(jump1Back)/\(jump1.ms)ms", "fj1=\(jump1End.units.count)/\(jump1End.reason)",
                 "pick=\(pick)", "agree=\(agreeAll)", "ms=\(ms)"]
        WalkNote.shared.set(note.joined(separator: " "))
        let text = String(decoding: whole, as: UTF16.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, false)
    }

    /// Cancel after a read (P6): the cursor goes back where it was before `read` moved it. The caller checks first
    /// that the text moved over is still just before the cursor (CursorReturn.back).
    static func restore(_ moved: Int, _ proxy: UITextDocumentProxy) {
        guard moved > 0 else { return }
        proxy.adjustTextPosition(byCharacterOffset: -moved)
    }

    /// Replace what `read` returned (cursor at the end, or the selection) with new text.
    static func replace(_ old: String, isSelection: Bool, with new: String, _ proxy: UITextDocumentProxy) {
        if isSelection {
            proxy.insertText(new)  // typing over a selection replaces it
            return
        }
        for _ in old { proxy.deleteBackward() }  // one grapheme per call
        proxy.insertText(new)
    }
}

/// diag/p1-walk-back: the last walk's numbers (lengths, counts, hashes, reasons, times; never text), which the CI
/// stub appends to its reply so the UI test reads them on the card.
final class WalkNote: @unchecked Sendable {
    static let shared = WalkNote()
    private let lock = NSLock()
    private var value = ""

    func set(_ s: String) {
        lock.lock()
        value = s
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
