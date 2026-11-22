import ProtlyCore
import UIKit
import os

/// Reads and replaces the whole field through the text document proxy (K1b). The proxy shows only a window around the
/// cursor, so the read walks the cursor to both ends (WholeRead in ProtlyCore holds the rules; this is the driver).
@MainActor
enum FieldText {
    /// Lengths, line-feed counts, hashes, reasons and timings only, never text (KeyboardSourceRulesTests).
    private static let log = Logger(subsystem: "com.northprot.protly", category: "read")

    /// The read's record of the cursor (CursorReturn). Every change goes to `report` at once: the keyboard keeps the
    /// latest copy for Cancel, which can come between any two steps.
    @MainActor
    final class Track {
        private(set) var cursor = CursorReturn()
        private let report: (CursorReturn) -> Void

        init(report: @escaping (CursorReturn) -> Void) {
            self.report = report
            report(cursor)
        }

        func sending() { cursor.sending(); report(cursor) }
        func landed(_ moved: Int?, _ before: String) { cursor.landed(moved: moved, before: before); report(cursor) }
        func reachedEnd(_ before: String) { cursor.reachedEnd(before: before); report(cursor) }
        /// Select all was collapsed: the user's place is now the field's end (the selection cannot come back).
        func restart() { cursor.begin(); report(cursor) }
    }

    enum Outcome {
        /// The whole field (the cursor at its end), or a partial selection (K1a: its card only copies).
        case text(String, isSelection: Bool)
        /// Nothing but whitespace: the protly key reads the clipboard.
        case empty
        /// Not proven whole: never sent (owner decision). The reason goes to the log only.
        case refused
        case cancelled
    }

    /// The last read's duration in ms: only the CI stub's reply reads it (StubActionClient, off the main actor; the
    /// phone build has no reader). Written on the main actor only; an Int, never text.
    nonisolated(unsafe) static var lastReadMS = 0

    private struct Ctx: Equatable {
        let b: String
        let a: String
        let s: String

        var before: [UInt16] { Array(b.utf16) }
        var after: [UInt16] { Array(a.utf16) }
    }

    private static func ctx(_ p: UITextDocumentProxy) -> Ctx {
        Ctx(b: p.documentContextBeforeInput ?? "", a: p.documentContextAfterInput ?? "", s: p.selectedText ?? "")
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func ms(since t: TimeInterval) -> Int { Int((uptime() - t) * 1000) }

    /// 20 ms that a cancel does not cut short (Task.sleep would end at once): a step on its way always settles.
    private static func pause(_ seconds: TimeInterval = WholeRead.poll) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    /// One move, then a poll every 20 ms until a context changes or `wait` passes; once changed, more polls until two
    /// in a row agree (the host's update can come in two parts: probe run 7f2f443-135).
    private static func step(_ p: UITextDocumentProxy, by k: Int, wait: TimeInterval) async -> (changed: Bool, c: Ctx) {
        let c0 = ctx(p)
        p.adjustTextPosition(byCharacterOffset: k)  // UTF-16 units on native hosts; characters on the web
        return await watch(p, from: c0, wait: wait)
    }

    /// Polls until the contexts differ from `c0` and settle, or `wait` passes.
    private static func watch(_ p: UITextDocumentProxy, from c0: Ctx, wait: TimeInterval) async -> (changed: Bool, c: Ctx) {
        let sent = uptime()
        while uptime() - sent < wait {
            await pause()
            var c1 = ctx(p)
            guard c1 != c0 else { continue }
            for _ in 0..<WholeRead.settlePolls {
                await pause()
                let c2 = ctx(p)
                if c2 == c1 { break }
                c1 = c2
            }
            return (true, c1)
        }
        // A last look: a stalled main thread can end the loop between two polls; never call that "no change".
        let last = ctx(p)
        return (last != c0, last)
    }

    private enum WalkEnd {
        case done(units: [UInt16])
        case failed(String)
        case cancelled
    }

    /// The longest a step can take: its wait, the settle polls and a margin for the main thread.
    private static func stepCost(_ wait: TimeInterval) -> TimeInterval {
        wait + Double(WholeRead.settlePolls + 1) * WholeRead.poll
    }

    /// One walk to the end (`back` false) or the start. Every step settles before the next check, so a cancel or the
    /// budget stops the walk only between steps.
    private static func walk(_ p: UITextDocumentProxy, back: Bool, cap: Int, tag: String, start t0: TimeInterval,
                             track: Track, progress: () -> Void) async -> WalkEnd {
        var bw = BackWalk(cap: cap)
        // Only the walk from the user's cursor may start from contexts the host never refreshed (run 163 web `mid`).
        var fw = ForwardWalk(cap: cap, resyncFirst: tag == "f")
        var steps = 0, late = 0, firstMS = -1
        let w0 = uptime()
        func fits(_ wait: TimeInterval) -> Bool {
            WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(wait))
        }
        func end(_ e: WalkEnd) -> WalkEnd {
            let units: [UInt16], reason: String
            switch e {
            case .done(let u): units = u; reason = "done"
            case .failed(let why): units = back ? bw.units : fw.units; reason = why
            case .cancelled: units = []; reason = "cancelled"
            }
            let count = units.count, lf = WholeRead.lineFeeds(units), hash = WholeRead.fnv(units), took = ms(since: w0)
            let retries = bw.retries, resyncs = fw.resyncs
            log.debug("read walk \(tag, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) reason=\(reason, privacy: .public) steps=\(steps, privacy: .public) ms=\(took, privacy: .public) first=\(firstMS, privacy: .public) retries=\(retries, privacy: .public) resyncs=\(resyncs, privacy: .public) late=\(late, privacy: .public)")
            return e
        }
        /// A step that fit nothing: the contexts' lengths and which of them fit, never their text.
        func logStep(_ why: String, k: Int, from c: Ctx, to s: (changed: Bool, c: Ctx), ms took: Int) {
            let fit = back ? bw.fit : fw.fit
            let b0 = c.before.count, a0 = c.after.count, b1 = s.c.before.count, a1 = s.c.after.count
            let fb = fit.before ? 1 : 0, fa = fit.after ? 1 : 0, ch = s.changed ? 1 : 0
            log.debug("read step \(tag, privacy: .public) s=\(steps, privacy: .public) why=\(why, privacy: .public) k=\(k, privacy: .public) b0=\(b0, privacy: .public) a0=\(a0, privacy: .public) b1=\(b1, privacy: .public) a1=\(a1, privacy: .public) fitb=\(fb, privacy: .public) fita=\(fa, privacy: .public) ch=\(ch, privacy: .public) ms=\(took, privacy: .public)")
        }
        while true {
            if Task.isCancelled { return end(.cancelled) }
            if uptime() - t0 >= WholeRead.progressAfter { progress() }
            var c = ctx(p)
            if back, c.before.isEmpty {
                // An empty before-context mid-field comes back within 0.3 s (run 471e282-153): wait before probing.
                guard fits(WholeRead.emptyWait + WholeRead.probeWait) else { return end(.failed("timeUp")) }
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                c = ctx(p)
            }
            let probing = back ? c.before.isEmpty : c.after.isEmpty
            let wait = probing ? WholeRead.probeWait : WholeRead.moveWait
            guard fits(wait) else { return end(.failed("timeUp")) }
            // A Cancel during the wait above already put the cursor back (no step was on its way): never move it again.
            if Task.isCancelled { return end(.cancelled) }
            let k = back ? bw.plan(before: c.before, after: c.after) : fw.plan(after: c.after)
            steps += 1
            track.sending()
            let s0 = uptime()
            var s = await step(p, by: back ? -k : k, wait: wait)
            if steps == 1 { firstMS = ms(since: s0) }
            if !s.changed, !probing, fits(WholeRead.moveWait) {
                // A move that has not shown after 1 s may still come (run 163 textarea: the first step back; steps
                // take 26-33 ms at the median, 286 ms at most in probe runs 154-155): one more look before "stuck".
                late += 1
                s = await watch(p, from: c, wait: WholeRead.moveWait)
            }
            if !back, s.changed, s.c.before.isEmpty {
                // An empty before-context after a step forward is a window on its way, not the field: wait for it.
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                s.c = ctx(p)
            }
            let r = back ? bw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
                : fw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
            if case .failed(let why, _) = r { logStep(why, k: k, from: c, to: s, ms: ms(since: s0)) }
            if !back, case .moved = r, fw.resyncs > 0, steps == 1 {
                logStep("resync", k: k, from: c, to: s, ms: ms(since: s0))
            }
            switch r {
            case .moved(let d):
                track.landed(d, s.c.b)
            case .phantom:
                track.landed(nil, s.c.b)
            case .retry(let m):
                // A false start: the probe moved one unit back over text it cannot name. Undo it and look again.
                track.landed(-1, s.c.b)
                logStep("falseStart", k: k, from: c, to: s, ms: ms(since: s0))
                if Task.isCancelled { return end(.cancelled) }
                guard fits(WholeRead.moveWait) else { return end(.failed("timeUp")) }
                track.sending()
                let u = await step(p, by: m, wait: WholeRead.moveWait)
                switch bw.undone(changed: u.changed, before: u.c.before, after: u.c.after) {
                case .moved(let d):
                    track.landed(d, u.c.b)
                default:
                    track.landed(nil, u.c.b)
                    return end(.failed("badUndo"))
                }
            case .done:
                if back {
                    track.landed(0, s.c.b)
                } else {
                    track.reachedEnd(s.c.b)
                }
                return end(.done(units: back ? bw.units : fw.units))
            case .failed(let why, let moved):
                track.landed(moved, s.c.b)
                return end(.failed(why))
            }
        }
    }

    /// One move forward by a walk's length, back to the end it started from. Counted only when the contexts show the
    /// end again (the probe saw returns land a few units short: runs 154, 155); the next walk confirms the end anyway.
    private static func returnMove(_ p: UITextDocumentProxy, by n: Int, end: Ctx, start t0: TimeInterval,
                                   track: Track) async -> Bool {
        guard n > 0 else { return true }
        guard WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(WholeRead.moveWait)) else { return false }
        track.sending()
        let s = await step(p, by: n, wait: WholeRead.moveWait)
        let atEnd = s.c.a.isEmpty && !s.c.b.isEmpty && WholeRead.agreeAtEnd(s.c.before, end.before)
        track.landed(atEnd ? n : nil, s.c.b)
        return true
    }

    /// The whole field, a partial selection, or a refusal. `record` gets the read's CursorReturn after every change
    /// (a step sent, a step settled, the end reached), for Cancel; `progress` is called while the read runs past
    /// WholeRead.progressAfter. Up to WholeRead.total (20 s) in all; the keys wait meanwhile.
    static func read(_ p: UITextDocumentProxy, record: @escaping (CursorReturn) -> Void,
                     progress: () -> Void) async -> Outcome {
        let t0 = uptime()
        let c0 = ctx(p)
        let track = Track(report: record)
        let sb = c0.before.count, sa = c0.after.count, ss = c0.s.utf16.count
        log.debug("read start b=\(sb, privacy: .public) a=\(sa, privacy: .public) s=\(ss, privacy: .public)")
        func finish(_ o: Outcome, _ reason: String, _ units: [UInt16] = []) -> Outcome {
            let outcome: String
            switch o {
            case .text: outcome = "accepted"
            case .empty: outcome = "empty"
            case .refused: outcome = "refused"
            case .cancelled: outcome = "cancelled"
            }
            let count = units.count, lf = WholeRead.lineFeeds(units), hash = WholeRead.fnv(units), took = ms(since: t0)
            let known = track.cursor.isKnown ? 1 : 0
            lastReadMS = took
            log.debug("read done outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) ms=\(took, privacy: .public) known=\(known, privacy: .public)")
            return o
        }
        func walk(_ back: Bool, cap: Int, _ tag: String) async -> WalkEnd {
            await FieldText.walk(p, back: back, cap: cap, tag: tag, start: t0, track: track, progress: progress)
        }
        /// A refusal puts the cursor back (the keyboard does, by the record). When a step since the field's end could
        /// not be named (a phantom at the start, a return that landed short), one more walk to the end makes the
        /// position known again first, within the same budget.
        func refuse(_ reason: String, _ units: [UInt16] = []) async -> Outcome {
            if !track.cursor.isKnown, track.cursor.hasEnd, !Task.isCancelled {
                if case .cancelled = await walk(false, cap: WholeRead.cap, "fr") {
                    return finish(.cancelled, "cancelled")
                }
            }
            return finish(.refused, reason, units)
        }
        /// A walk that did not end where it should: the read is refused, or was cancelled.
        func stopped(_ e: WalkEnd, _ tag: String) async -> Outcome {
            switch e {
            case .cancelled: return finish(.cancelled, "cancelled")
            case .failed(let why): return await refuse("\(tag):\(why)")
            case .done: return await refuse("\(tag):done")  // not reached: callers pass only a walk that stopped
            }
        }
        if !c0.s.isEmpty {
            // K1a: a partial selection is its own text, and its card only copies. Select all shows no context on
            // either side (run 471e282-153: `before=nil after=nil sel=43/0` every time) and selectedText only its
            // first 43 units, so it is collapsed to the end (+1 lands there, run 7f2f443-135) and the field read whole.
            guard c0.b.isEmpty, c0.a.isEmpty else { return finish(.text(c0.s, isSelection: true), "selection") }
            track.sending()
            let s = await step(p, by: 1, wait: WholeRead.moveWait)
            // Where the collapse left the cursor is the user's place now: the selection cannot come back.
            track.restart()
            if Task.isCancelled { return finish(.cancelled, "cancelled") }
            guard s.changed, s.c.s.isEmpty else { return finish(.refused, "collapse") }
        }
        // F: to the end. Its steps all fit the contexts, so it fixes where the end is from the user's cursor.
        let fEnd = await walk(false, cap: WholeRead.cap, "f")
        guard case .done(let first) = fEnd else { return await stopped(fEnd, "f") }
        let end = ctx(p)
        // B1: back to the start.
        let b1End = await walk(true, cap: WholeRead.cap, "b1")
        guard case .done(let back1) = b1End else { return await stopped(b1End, "b1") }
        // An empty field (no text crossed either way): nothing to read twice.
        if back1.isEmpty, first.isEmpty { return finish(.empty, "empty") }
        // R1 and FM: forward again, confirm the end. B2: the second walk back may not read more than the first.
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        guard await returnMove(p, by: back1.count, end: end, start: t0, track: track) else {
            return await refuse("r1:timeUp")
        }
        let fmEnd = await walk(false, cap: WholeRead.cap, "fm")
        guard case .done(let mid) = fmEnd else { return await stopped(fmEnd, "fm") }
        let b2End = await walk(true, cap: back1.count, "b2")
        guard case .done(let back2) = b2End else { return await stopped(b2End, "b2") }
        // R2 and FE: the cursor goes to the end for Replace, and the end is confirmed once more.
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        guard await returnMove(p, by: back2.count, end: end, start: t0, track: track) else {
            return await refuse("r2:timeUp")
        }
        let feEnd = await walk(false, cap: WholeRead.cap, "fe")
        guard case .done(let last) = feEnd else { return await stopped(feEnd, "fe") }
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        if let why = WholeRead.refusal(first: first, back1: back1, mid: mid, back2: back2, last: last) {
            return await refuse(why, back1)
        }
        let text = String(decoding: back1, as: UTF16.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return finish(.empty, "whitespace", back1) }
        return finish(.text(text, isSelection: false), "-", back1)
    }

    /// Cancel or a refusal (P6): the cursor goes back by `move` (CursorReturn.back) in one step. The probe saw such a
    /// move miss by a few units beyond about 3230 units and on the Lexical-shaped page; a miss is logged, not fixed.
    /// `known` false: the read's record lost the position (a phantom step), so the cursor stays where the read left it.
    static func restore(_ move: Int, known: Bool, _ p: UITextDocumentProxy) {
        let units = abs(move), position = known ? 1 : 0
        log.debug("read restore units=\(units, privacy: .public) known=\(position, privacy: .public)")
        guard move != 0 else { return }
        p.adjustTextPosition(byCharacterOffset: move)
    }

    /// Host callbacks (textDidChange, selectionDidChange) so far: Replace waits until they stop (KeyboardViewController
    /// counts them). The proxy shows the keyboard's own deletes and insert at once, long before the host has applied
    /// them (run 162: an empty field 0.36 s after 3247 deletes the host needed 7-12 s for).
    static var hostEvents = 0

    /// Replace `old` (the whole field, the cursor at its end) with `new`: one deleteBackward per Character of `old`,
    /// then, once the proxy shows them, the insert (runs 162, 163: every Replace then left exactly the result). The
    /// host applies them in order, seconds after the proxy shows them, and on web hosts tells the keyboard nothing
    /// meanwhile (run e070adc-172), so no move goes out before WholeRead.replaceSettle (a move sent while the
    /// Lexical-shaped page was still deleting left it empty, run 172). Then the contexts must show `new`'s end and be
    /// still for WholeRead.quiet, within WholeRead.replaceLimit; then a walk back over the result to the start must read
    /// exactly `new` (a window shows only the end, so old text left in front would be invisible to the contexts
    /// alone), and a walk forward must reach the end over `new`'s last units. false: not proven (or the keyboard was
    /// hidden: the Task is cancelled); the caller says so and offers no Undo.
    static func replace(_ old: String, with new: String, _ p: UITextDocumentProxy) async -> Bool {
        let t0 = uptime()
        let events0 = hostEvents
        var deleted = 0
        for _ in old {
            p.deleteBackward()  // one Character per call
            deleted += 1
        }
        let sent = ms(since: t0)
        var emptied = deleted == 0
        while !emptied, uptime() - t0 < WholeRead.moveWait, !Task.isCancelled {
            await pause(0.05)
            emptied = shows("", ctx(p))
        }
        let emptyMS = ms(since: t0)
        p.insertText(new)
        let settle = t0 + WholeRead.replaceSettle(deletes: deleted)
        let deadline = t0 + WholeRead.replaceLimit(deletes: deleted)
        var last = ctx(p), events = hostEvents, quietFrom = uptime(), changes = 0
        var firstEvent = -1, lastEvent = -1, lastChange = -1
        var shown = false
        while uptime() < deadline, !Task.isCancelled {
            await pause(0.05)
            let c = ctx(p)
            if hostEvents != events {
                if firstEvent < 0 { firstEvent = ms(since: t0) }
                lastEvent = ms(since: t0)
                events = hostEvents
                quietFrom = uptime()
            }
            if c != last {
                changes += 1
                lastChange = ms(since: t0)
                last = c
                quietFrom = uptime()
            }
            if uptime() >= settle, uptime() - quietFrom >= WholeRead.quiet, shows(new, c) {
                shown = true
                break
            }
        }
        let quietMS = ms(since: t0)
        let c = ctx(p)
        let lb = c.before.count, la = c.after.count, ends = new.utf16.reversed().starts(with: c.before.reversed()) ? 1 : 0
        let held = shown && !Task.isCancelled ? await holds(new, p) : false
        let inserted = new.utf16.count, heldMS = ms(since: t0), ok = held ? 1 : 0, gate = shown ? 1 : 0
        let empty = emptied ? 1 : 0, seen = hostEvents - events0, cancelled = Task.isCancelled ? 1 : 0
        log.debug("replace deleted=\(deleted, privacy: .public) inserted=\(inserted, privacy: .public) sentms=\(sent, privacy: .public) emptyms=\(emptyMS, privacy: .public) empty=\(empty, privacy: .public) quietms=\(quietMS, privacy: .public) quiet=\(gate, privacy: .public) changes=\(changes, privacy: .public) lastch=\(lastChange, privacy: .public) events=\(seen, privacy: .public) firstev=\(firstEvent, privacy: .public) lastev=\(lastEvent, privacy: .public) b=\(lb, privacy: .public) a=\(la, privacy: .public) ends=\(ends, privacy: .public) heldms=\(heldMS, privacy: .public) held=\(ok, privacy: .public) cancelled=\(cancelled, privacy: .public)")
        return held
    }

    /// The contexts show `new` as the whole field's end with the cursor there (an empty result: an empty field).
    private static func shows(_ new: String, _ c: Ctx) -> Bool {
        new.isEmpty ? c.b.isEmpty && c.a.isEmpty : FieldGuard.holdsResult(new, before: c.b, after: c.a)
    }

    /// The field is exactly `new` with the cursor at its end: a walk back reads exactly `new` to the start, a move
    /// forward by its length, and a walk forward reaches the end over `new`'s last units (a long move can land a few
    /// units short: probe runs 154, 155). Called once the host has had its time and the contexts show `new`'s end.
    private static func holds(_ new: String, _ p: UITextDocumentProxy) async -> Bool {
        let units = Array(new.utf16)
        guard !units.isEmpty else { return !p.hasText }
        let t0 = uptime()
        let none = Track { _ in }
        guard case .done(let read) = await walk(p, back: true, cap: units.count, tag: "v", start: t0, track: none,
                                                progress: {}),
              read == units else { return false }
        let s = await step(p, by: units.count, wait: WholeRead.moveWait)
        guard s.changed, case .done(let rest) = await walk(p, back: false, cap: units.count, tag: "ve", start: t0,
                                                            track: none, progress: {})
        else { return false }
        return Array(units.suffix(rest.count)) == rest
    }
}
