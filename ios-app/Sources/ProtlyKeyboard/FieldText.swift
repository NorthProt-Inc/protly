import ProtlyCore
import UIKit
import os

/// Reads and replaces the whole field through the text document proxy (K1b). The proxy shows only a window around the
/// cursor, so the read walks the cursor to both ends (WholeRead in ProtlyCore holds the rules; this is the driver).
@MainActor
enum FieldText {
    /// Lengths, line-feed counts, hashes, reasons and timings only, never text (KeyboardSourceRulesTests).
    private static let log = Logger(subsystem: "com.northprot.protly", category: "read")

    /// One cursor step of a read, for Cancel (CursorReturn).
    enum Move {
        case sending
        /// The step settled: its move in UTF-16 units, nil when it cannot be named; the before-context now.
        case landed(moved: Int?, before: String)
        /// An accepted read: the cursor is at the field's end, this many units past where the user had it.
        case confirmedEnd(fromOrigin: Int, before: String)
    }

    enum Outcome {
        /// The whole field (the cursor at its end), or a partial selection (K1a: its card only copies).
        case text(String, isSelection: Bool)
        /// Nothing but whitespace: the protly key reads the clipboard.
        case empty
        /// Not proven whole: never sent (owner decision).
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
        let sent = uptime()
        p.adjustTextPosition(byCharacterOffset: k)  // UTF-16 units on native hosts; characters on the web
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
                             record: (Move) -> Void, progress: () -> Void) async -> WalkEnd {
        var bw = BackWalk(cap: cap)
        var fw = ForwardWalk(cap: cap)
        var steps = 0
        let w0 = uptime()
        func end(_ e: WalkEnd) -> WalkEnd {
            let units: [UInt16], reason: String
            switch e {
            case .done(let u): units = u; reason = "done"
            case .failed(let why): units = back ? bw.units : fw.units; reason = why
            case .cancelled: units = []; reason = "cancelled"
            }
            let count = units.count, lf = WholeRead.lineFeeds(units), hash = WholeRead.fnv(units), took = ms(since: w0)
            log.debug("read walk \(tag, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) reason=\(reason, privacy: .public) steps=\(steps, privacy: .public) ms=\(took, privacy: .public)")
            return e
        }
        while true {
            if Task.isCancelled { return end(.cancelled) }
            if uptime() - t0 >= WholeRead.progressAfter { progress() }
            var c = ctx(p)
            if back, c.before.isEmpty {
                // An empty before-context mid-field comes back within 0.3 s (run 471e282-153): wait before probing.
                guard WholeRead.canStart(elapsed: uptime() - t0, wait: WholeRead.emptyWait + stepCost(WholeRead.probeWait)) else {
                    return end(.failed("timeUp"))
                }
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                c = ctx(p)
            }
            let probing = back ? c.before.isEmpty : c.after.isEmpty
            let wait = probing ? WholeRead.probeWait : WholeRead.moveWait
            guard WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(wait)) else { return end(.failed("timeUp")) }
            let k = back ? bw.plan(before: c.before, after: c.after) : fw.plan(after: c.after)
            steps += 1
            record(.sending)
            var s = await step(p, by: back ? -k : k, wait: wait)
            if !back, s.changed, s.c.before.isEmpty {
                // An empty before-context after a step forward is a window on its way, not the field: wait for it.
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                s.c = ctx(p)
            }
            let r = back ? bw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
                : fw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
            switch r {
            case .moved(let d):
                record(.landed(moved: d, before: s.c.b))
            case .phantom:
                record(.landed(moved: nil, before: s.c.b))
            case .done:
                record(.landed(moved: 0, before: s.c.b))
                return end(.done(units: back ? bw.units : fw.units))
            case .failed(let why, let moved):
                record(.landed(moved: moved, before: s.c.b))
                return end(.failed(why))
            }
        }
    }

    /// One move forward by a walk's length, back to the end it started from. Counted only when the contexts show the
    /// end again (the probe saw returns land a few units short: runs 154, 155); the next walk confirms the end anyway.
    private static func returnMove(_ p: UITextDocumentProxy, by n: Int, end: Ctx, start t0: TimeInterval,
                                   record: (Move) -> Void) async -> Bool {
        guard n > 0 else { return true }
        guard WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(WholeRead.moveWait)) else { return false }
        record(.sending)
        let s = await step(p, by: n, wait: WholeRead.moveWait)
        let atEnd = s.c.a.isEmpty && !s.c.b.isEmpty && WholeRead.agreeAtEnd(s.c.before, end.before)
        record(.landed(moved: atEnd ? n : nil, before: s.c.b))
        return true
    }

    /// The whole field, a partial selection, or a refusal. `record` gets each cursor step as it is sent and once it
    /// settled (CursorReturn); `progress` is called while the read runs past WholeRead.progressAfter. Up to
    /// WholeRead.total (20 s) in all; the keys wait meanwhile.
    static func read(_ p: UITextDocumentProxy, record: (Move) -> Void, progress: () -> Void) async -> Outcome {
        let t0 = uptime()
        let c0 = ctx(p)
        func finish(_ o: Outcome, _ reason: String, _ units: [UInt16] = []) -> Outcome {
            let outcome: String
            switch o {
            case .text: outcome = "accepted"
            case .empty: outcome = "empty"
            case .refused: outcome = "refused"
            case .cancelled: outcome = "cancelled"
            }
            let count = units.count, lf = WholeRead.lineFeeds(units), hash = WholeRead.fnv(units), took = ms(since: t0)
            lastReadMS = took
            log.debug("read done outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) ms=\(took, privacy: .public)")
            return o
        }
        if !c0.s.isEmpty {
            // K1a: a partial selection is its own text, and its card only copies. Select all shows no context on
            // either side (run 471e282-153: `before=nil after=nil sel=43/0` every time) and selectedText only its
            // first 43 units, so it is collapsed to the end (+1 lands there, run 7f2f443-135) and the field read whole.
            guard c0.b.isEmpty, c0.a.isEmpty else { return finish(.text(c0.s, isSelection: true), "selection") }
            let s = await step(p, by: 1, wait: WholeRead.moveWait)
            guard s.changed, s.c.s.isEmpty else { return finish(.refused, "collapse") }
            if Task.isCancelled { return finish(.cancelled, "cancelled") }
        }
        func walk(_ back: Bool, cap: Int, _ tag: String) async -> WalkEnd {
            await FieldText.walk(p, back: back, cap: cap, tag: tag, start: t0, record: record, progress: progress)
        }
        // F: to the end. Its steps all fit the contexts, so its length is where the user had the cursor.
        let fEnd = await walk(false, cap: WholeRead.cap, "f")
        if case .cancelled = fEnd { return finish(.cancelled, "cancelled") }
        guard case .done(let first) = fEnd else { return finish(.refused, "f") }
        let end = ctx(p)
        // B1: back to the start.
        let b1End = await walk(true, cap: WholeRead.cap, "b1")
        if case .cancelled = b1End { return finish(.cancelled, "cancelled") }
        guard case .done(let back1) = b1End else { return finish(.refused, "b1") }
        // An empty field (no text crossed either way): nothing to read twice.
        if back1.isEmpty, first.isEmpty { return finish(.empty, "empty") }
        // R1 and FM: forward again, confirm the end. B2: the second walk back may not read more than the first.
        guard await returnMove(p, by: back1.count, end: end, start: t0, record: record) else { return finish(.refused, "timeUp") }
        let fmEnd = await walk(false, cap: WholeRead.cap, "fm")
        if case .cancelled = fmEnd { return finish(.cancelled, "cancelled") }
        guard case .done(let mid) = fmEnd else { return finish(.refused, "fm") }
        let b2End = await walk(true, cap: back1.count, "b2")
        if case .cancelled = b2End { return finish(.cancelled, "cancelled") }
        guard case .done(let back2) = b2End else { return finish(.refused, "b2") }
        // R2 and FE: the cursor goes to the end for Replace, and the end is confirmed once more.
        guard await returnMove(p, by: back2.count, end: end, start: t0, record: record) else { return finish(.refused, "timeUp") }
        let feEnd = await walk(false, cap: WholeRead.cap, "fe")
        if case .cancelled = feEnd { return finish(.cancelled, "cancelled") }
        guard case .done(let last) = feEnd else { return finish(.refused, "fe") }
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        if let why = WholeRead.refusal(back1: back1, mid: mid, back2: back2, last: last) {
            return finish(.refused, why, back1)
        }
        record(.confirmedEnd(fromOrigin: first.count, before: ctx(p).b))
        let text = String(decoding: back1, as: UTF16.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return finish(.empty, "whitespace", back1) }
        return finish(.text(text, isSelection: false), "-", back1)
    }

    /// Cancel or a refusal (P6): the cursor goes back by `move` (CursorReturn.back) in one step. The probe saw such a
    /// move miss by a few units beyond about 3230 units and on the Lexical-shaped page; a miss is logged, not fixed.
    static func restore(_ move: Int, _ p: UITextDocumentProxy) {
        guard move != 0 else { return }
        p.adjustTextPosition(byCharacterOffset: move)
        let units = abs(move)
        log.debug("read restore units=\(units, privacy: .public)")
    }

    /// Replace what `read` returned (the cursor at the field's end) with `new`: one deleteBackward per Character of
    /// the read, then a wait until the field is empty, then the insert, then a check that the field holds the result.
    /// `emptied` false: the field never showed empty within 5 s; the result was inserted anyway and the caller says so.
    static func replace(_ old: String, with new: String, _ p: UITextDocumentProxy) async -> (emptied: Bool, held: Bool) {
        let t0 = uptime()
        var deleted = 0
        for _ in old {
            p.deleteBackward()  // one Character per call
            deleted += 1
        }
        let sent = ms(since: t0)
        let emptied = await waitEmpty(p, limit: 5)
        let emptyMS = ms(since: t0)
        p.insertText(new)
        var held = false
        let h0 = uptime()
        while uptime() - h0 < 2 {
            await pause(0.05)
            let c = ctx(p)
            if FieldGuard.holdsResult(new, before: c.b, after: c.a) {
                held = true
                break
            }
        }
        let inserted = new.utf16.count, heldMS = ms(since: t0), empty = emptied ? 1 : 0, ok = held ? 1 : 0
        log.debug("replace deleted=\(deleted, privacy: .public) inserted=\(inserted, privacy: .public) sentms=\(sent, privacy: .public) emptyms=\(emptyMS, privacy: .public) empty=\(empty, privacy: .public) heldms=\(heldMS, privacy: .public) held=\(ok, privacy: .public)")
        return (emptied, held)
    }

    /// The field is empty: both contexts empty for WholeRead.emptyWait, and the proxy has no text or a one-unit probe
    /// back changes nothing (the start). A probe that moved is undone.
    private static func waitEmpty(_ p: UITextDocumentProxy, limit: TimeInterval) async -> Bool {
        let t0 = uptime()
        while uptime() - t0 < limit {
            await pause(0.05)
            guard ctx(p).b.isEmpty, ctx(p).a.isEmpty else { continue }
            let e0 = uptime()
            var stayed = true
            while uptime() - e0 < WholeRead.emptyWait {
                await pause()
                if !ctx(p).b.isEmpty || !ctx(p).a.isEmpty {
                    stayed = false
                    break
                }
            }
            guard stayed else { continue }
            if !p.hasText { return true }
            let s = await step(p, by: -1, wait: WholeRead.probeWait)
            guard s.changed else { return true }
            _ = await step(p, by: 1, wait: WholeRead.moveWait)
            return false
        }
        return false
    }
}
