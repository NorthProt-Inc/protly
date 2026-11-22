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
    private static func step(_ p: UITextDocumentProxy, by k: Int, wait: TimeInterval) async -> (changed: Bool, c: Ctx, seen: Int) {
        let c0 = ctx(p)
        p.adjustTextPosition(byCharacterOffset: k)  // UTF-16 units on native hosts; characters on the web
        return await watch(p, from: c0, wait: wait)
    }

    /// Polls until the contexts differ from `c0` and settle, or `wait` passes.
    /// `seen`: ms from the start of the watch to the first poll that saw a change, -1 for none.
    private static func watch(_ p: UITextDocumentProxy, from c0: Ctx, wait: TimeInterval) async -> (changed: Bool, c: Ctx, seen: Int) {
        let sent = uptime()
        while uptime() - sent < wait {
            await pause()
            var c1 = ctx(p)
            guard c1 != c0 else { continue }
            let seen = ms(since: sent)
            for _ in 0..<WholeRead.settlePolls {
                await pause()
                let c2 = ctx(p)
                if c2 == c1 { break }
                c1 = c2
            }
            return (true, c1, seen)
        }
        // A last look: a stalled main thread can end the loop between two polls; never call that "no change".
        let last = ctx(p)
        return (last != c0, last, last != c0 ? ms(since: sent) : -1)
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
    /// `read`: for a walk back, called with the units read so far after every step that read some (F02c: the read
    /// cancels the speculative call as soon as they are not the window's end). `lastWalkClean` says afterwards whether
    /// the walk undid no false start or end, met no phantom and needed no resync.
    private static func walk(_ p: UITextDocumentProxy, back: Bool, cap: Int, tag: String, start t0: TimeInterval,
                             track: Track, progress: () -> Void, read: ([UInt16]) -> Void = { _ in },
                             here: () -> Bool = { true }) async -> WalkEnd {
        // The second walk back steps elsewhere than the first (silent-failure review).
        var bw = BackWalk(cap: cap, shifted: tag == "b2")
        // Only the walk from the user's cursor may start from contexts the host never refreshed (run 163 web `mid`).
        var fw = ForwardWalk(cap: cap, resyncFirst: tag == "f")
        var steps = 0, late = 0, firstMS = -1, phantoms = 0
        // F02c: the host's contexts were seen on their way (a blank that came back, a second look, a step judged again):
        // the window proof is not taken after such a walk (run 20c073c-216 uikit win t2: after a blank, a start probe
        // that showed nothing for 0.5 s, then contexts that lagged into R1 and FM).
        var lagged = false
        let w0 = uptime()
        defer {
            lastWalkClean = bw.retries == 0 && fw.retries == 0 && fw.resyncs == 0 && phantoms == 0 && late == 0 && !lagged
            lastWalkResynced = fw.resyncs > 0
        }
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
            // No hash here: a walk's piece can be a few units long, and a 32-bit hash of so little can be reversed (code
            // review). `read done` hashes the whole read.
            let count = units.count, lf = WholeRead.lineFeeds(units), took = ms(since: w0)
            let retries = bw.retries + fw.retries, resyncs = fw.resyncs
            log.debug("read walk \(tag, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) reason=\(reason, privacy: .public) steps=\(steps, privacy: .public) ms=\(took, privacy: .public) first=\(firstMS, privacy: .public) retries=\(retries, privacy: .public) resyncs=\(resyncs, privacy: .public) late=\(late, privacy: .public)")
            return e
        }
        /// A step that fit nothing: the contexts' lengths and which of them fit, never their text.
        func logStep(_ why: String, k: Int, from c: Ctx, to s: (changed: Bool, c: Ctx, seen: Int), ms took: Int) {
            let fit = back ? bw.fit : fw.fit
            let b0 = c.before.count, a0 = c.after.count, b1 = s.c.before.count, a1 = s.c.after.count
            let fb = fit.before ? 1 : 0, fa = fit.after ? 1 : 0, ch = s.changed ? 1 : 0
            log.debug("read step \(tag, privacy: .public) s=\(steps, privacy: .public) why=\(why, privacy: .public) k=\(k, privacy: .public) b0=\(b0, privacy: .public) a0=\(a0, privacy: .public) b1=\(b1, privacy: .public) a1=\(a1, privacy: .public) fitb=\(fb, privacy: .public) fita=\(fa, privacy: .public) ch=\(ch, privacy: .public) ms=\(took, privacy: .public)")
        }
        while true {
            if Task.isCancelled { return end(.cancelled) }
            // Another field has the keyboard now (Replace's check: the user tapped one): never move its cursor.
            guard here() else { return end(.failed("focus")) }
            if uptime() - t0 >= WholeRead.progressAfter { progress() }
            var c = ctx(p)
            if back, c.before.isEmpty {
                // An empty before-context mid-field comes back within 0.3 s (run 471e282-153): wait before probing.
                guard fits(WholeRead.emptyWait + WholeRead.probeWait) else { return end(.failed("timeUp")) }
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                c = ctx(p)
                if !c.before.isEmpty { lagged = true }  // a blank mid-field that came back
            }
            let probing = back ? c.before.isEmpty : c.after.isEmpty
            let wait = probing ? WholeRead.probeWait : WholeRead.moveWait
            guard fits(wait) else { return end(.failed("timeUp")) }
            // A Cancel during the wait above already put the cursor back (no step was on its way): never move it again.
            if Task.isCancelled { return end(.cancelled) }
            let k = back ? bw.plan(before: c.before, after: c.after) : fw.plan(before: c.before, after: c.after)
            steps += 1
            track.sending()
            let s0 = uptime()
            var s = await step(p, by: back ? -k : k, wait: wait)
            if steps == 1 { firstMS = ms(since: s0) }
            if s.changed, uptime() - s0 > WholeRead.slowStep { slowSeen = true }
            // A move that has not shown may still come (run 163 textarea: the first step back took over 1 s; steps take
            // 26-33 ms at the median, 286 ms at most in probe runs 154-155): one more look before "stuck". A probe's
            // "nothing changed" gets it too once this read or Replace has seen a slow step (run b039057-182 textarea
            // mid: a probe at a line feed that showed late ended the first walk 39 units early; silent-failure review:
            // such an end in every walk would accept a partial read). A host that has been fast pays nothing: every
            // read has five such probes (run 7cdefa4-180: the main suite ran past its deadline on the reads' time).
            let second = !s.changed && (!probing || slowSeen)
            // No time left for that look: nothing changed is then no end, no start, only out of time.
            let outOfTime = second && !fits(wait)
            if second, !outOfTime {
                late += 1
                s = await watch(p, from: c, wait: wait)
                if s.changed { slowSeen = true }
            }
            if s.changed, s.c.before.isEmpty, !back || !probing {
                // An empty before-context after a step forward, or after a jump back (which always leaves text before
                // the cursor), is a window on its way, not the field: wait for it (run 0f1bcd6-185 swiftui emoji).
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                s.c = ctx(p)
                // It came back: the host's contexts lagged. (Still empty after a step over the whole context: the start.)
                if !s.c.before.isEmpty { lagged = true }
            }
            func judge() -> WalkStep {
                back ? bw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
                    : fw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
            }
            var r = judge()
            if case .failed(let why, _) = r, why == "badStep" || why == "characters", fits(WholeRead.emptyWait) {
                // A pair of contexts caught half-updated (run 185 uikit win: two polls 20 ms apart agreed on it): judged
                // once more on the contexts a moment later. The walk changes nothing until a step fits.
                await pause(WholeRead.emptyWait)
                let again = ctx(p)
                // Never on an empty before-context: it agrees with anything (silent-failure review, round 2).
                lagged = true
                if again != s.c, !again.before.isEmpty {
                    logStep("rejudged:\(why)", k: k, from: c, to: s, ms: ms(since: s0))
                    s.c = again
                    r = judge()
                }
            }
            if outOfTime { r = .failed("timeUp", moved: nil) }
            // Every step's timing, for the probe waits (F02c): numbers only.
            let pr = probing ? 1 : 0, ch = s.changed ? 1 : 0, lk = second && !outOfTime ? 1 : 0, tot = ms(since: s0)
            let seenMS = s.seen
            log.debug("read st \(tag, privacy: .public) s=\(steps, privacy: .public) k=\(k, privacy: .public) pr=\(pr, privacy: .public) ch=\(ch, privacy: .public) seen=\(seenMS, privacy: .public) tot=\(tot, privacy: .public) lk=\(lk, privacy: .public)")
            if case .failed(let why, _) = r { logStep(why, k: k, from: c, to: s, ms: ms(since: s0)) }
            if !back, case .moved = r, fw.resyncs > 0, steps == 1 {
                logStep("resync", k: k, from: c, to: s, ms: ms(since: s0))
            }
            switch r {
            case .moved(let d):
                track.landed(d, s.c.b)
                read(back ? bw.units : fw.units)
            case .phantom:
                phantoms += 1
                track.landed(nil, s.c.b)
            case .retry(let m):
                // A false start or end: the probe moved one unit over text it cannot name. Undo it and look again.
                track.landed(-m, s.c.b)
                logStep(back ? "falseStart" : "falseEnd", k: k, from: c, to: s, ms: ms(since: s0))
                if Task.isCancelled { return end(.cancelled) }
                guard fits(WholeRead.moveWait) else { return end(.failed("timeUp")) }
                track.sending()
                let u = await step(p, by: m, wait: WholeRead.moveWait)
                let undone = back ? bw.undone(changed: u.changed, before: u.c.before, after: u.c.after)
                    : fw.undone(changed: u.changed, before: u.c.before, after: u.c.after)
                switch undone {
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
    /// nil: no time left for the move. Else whether the contexts show the end again (F02c's window proof needs it).
    /// The contexts settled after a return can still be on their way (run 1b402b4-204 uikit smid: two polls agreed on
    /// a before-context of the line before the end, with nothing after the cursor, then FM's probe saw the end's and
    /// called it a bad step): with nothing after the cursor they get up to WholeRead.emptyWait to show the end. Text
    /// after the cursor is a return that landed short (the Lexical-shaped page, 2 units after its phantom): no wait
    /// (run 52eeb7e-217: waiting there too put two Lexical long reads past the 20 s budget).
    private static func returnMove(_ p: UITextDocumentProxy, by n: Int, end: Ctx, start t0: TimeInterval,
                                   track: Track) async -> Bool? {
        guard n > 0 else { return false }
        guard WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(WholeRead.moveWait) + WholeRead.emptyWait) else {
            return nil
        }
        track.sending()
        let s = await step(p, by: n, wait: WholeRead.moveWait)
        func showsEnd(_ c: Ctx) -> Bool { c.a.isEmpty && !c.b.isEmpty && WholeRead.agreeAtEnd(c.before, end.before) }
        var c = s.c, atEnd = showsEnd(c)
        lastReturnWaited = !atEnd && c.a.isEmpty
        let e0 = uptime()
        while !atEnd, c.a.isEmpty, uptime() - e0 < WholeRead.emptyWait {
            await pause()
            c = ctx(p)
            atEnd = showsEnd(c)
        }
        track.landed(atEnd ? n : nil, c.b)
        return atEnd
    }

    /// The walk that ended last was clean, or resynced at its first step (see walk).
    private static var lastWalkClean = true
    private static var lastWalkResynced = false
    /// The last return's contexts needed the extra wait to show the end (a lag signal for the window proof).
    private static var lastReturnWaited = false

    /// The whole field, a partial selection, or a refusal. `record` gets the read's CursorReturn after every change
    /// (a step sent, a step settled, the end reached), for Cancel; `progress` is called while the read runs past
    /// WholeRead.progressAfter. Up to WholeRead.total (20 s) in all; the keys wait meanwhile.
    ///
    /// F02c: `window` gets, at most once, the text the proxy's window shows: both contexts at the tap, or for select all
    /// those at the field's end once the walk there showed it was select all (never for a partial selection). The
    /// keyboard starts its speculative call on it. `left` is called at most once, as soon as a walk shows the field is
    /// not that text: the keyboard cancels the call then. When B1 reads exactly the window, R1 lands at the end and FM
    /// crosses nothing (WholeRead.windowProof), the read is proven there, without B2, R2 and FE.
    static func read(_ p: UITextDocumentProxy, record: @escaping (CursorReturn) -> Void,
                     progress: () -> Void, window: (String) -> Void = { _ in },
                     left: (String) -> Void = { _ in }) async -> Outcome {
        let t0 = uptime()
        let c0 = ctx(p)
        let track = Track(report: record)
        slowSeen = false
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
            log.debug("read done outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) ms=\(took, privacy: .public) known=\(known, privacy: .public)")
            return o
        }
        // The window's text (F02c): the speculative call's, and the window proof's.
        var shown: [UInt16]?
        /// The read can no longer be the window's text (`longer`), or will not be accepted at all (`refused`).
        func leave(_ why: String) {
            guard shown != nil else { return }
            shown = nil
            left(why)
        }
        func show(_ c: Ctx) {
            let units = c.before + c.after
            guard !String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            shown = units
            window(c.b + c.a)
        }
        func walk(_ back: Bool, cap: Int, _ tag: String) async -> WalkEnd {
            await FieldText.walk(p, back: back, cap: cap, tag: tag, start: t0, track: track, progress: progress) { read in
                guard let w = shown else { return }
                // A walk back read text the window did not end with; F crossed more than the window showed after the
                // cursor: the field is not the window's text (silent-failure review: cancel the call at once).
                if back ? !WholeRead.withinWindow(w, read) : tag == "f" && read.count > c0.after.count { leave("longer") }
            }
        }
        /// A refusal puts the cursor back (the keyboard does, by the record). When a step since the field's end could
        /// not be named (a phantom at the start, a return that landed short), one more walk to the end makes the
        /// position known again first, within the same budget.
        func refuse(_ reason: String, _ units: [UInt16] = []) async -> Outcome {
            leave("refused")
            if !track.cursor.isKnown, track.cursor.hasEnd, !Task.isCancelled {
                if case .cancelled = await walk(false, cap: WholeRead.cap, "fr") {
                    return finish(.cancelled, "cancelled")
                }
            }
            return finish(.refused, reason, units)
        }
        /// A walk that did not end where it should: the read is refused, or was cancelled.
        func stopped(_ e: WalkEnd, _ tag: String) async -> Outcome {
            leave("refused")
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
        } else {
            show(c0)
        }
        // F: to the end. Its steps all fit the contexts, so it fixes where the end is from the user's cursor.
        let fEnd = await walk(false, cap: WholeRead.cap, "f")
        guard case .done(let first) = fEnd else { return await stopped(fEnd, "f") }
        var clean = lastWalkClean
        let fResynced = lastWalkResynced
        if let w = shown, !WholeRead.withinWindow(w, first) { leave("longer") }
        if !c0.s.isEmpty, !first.isEmpty || fResynced {
            // Not select all (WholeRead.collapsed): a partial selection from the field's start to a line feed also shows
            // both contexts empty (tower review of f0533ae). K1a, a copy-only card of its own text, only when the
            // before-context back where the collapse left the cursor is exactly selectedText; else refused. A resync
            // alone: the +1 may not have moved (the collapse was at the end already), so the cursor stays.
            var before: [UInt16] = []
            if first.isEmpty {
                track.landed(nil, ctx(p).b)
            } else {
                let move = track.cursor.back(before: ctx(p).b)
                if move != 0 {
                    track.sending()
                    let s = await step(p, by: move, wait: WholeRead.moveWait)
                    track.landed(nil, s.c.b)
                }
                // A native window stops at a line feed: right after the one the collapse crossed it shows nothing (run
                // 8be8a93-218). One unit back, at the selection's end, it shows the selection's line.
                if ctx(p).before.isEmpty, !Task.isCancelled {
                    track.sending()
                    let s = await step(p, by: -1, wait: WholeRead.moveWait)
                    track.landed(nil, s.c.b)
                }
                before = ctx(p).before
            }
            switch WholeRead.collapsed(crossed: first, resynced: fResynced, selected: Array(c0.s.utf16), before: before) {
            case .partial: return finish(.text(c0.s, isSelection: true), "partialSelection")
            case .selectAll, .unknown: return finish(.refused, first.isEmpty ? "collapse:resync" : "collapse:unproven")
            }
        }
        let end = ctx(p)
        // Select all: the window is the field's end now that the walk there crossed nothing.
        if !c0.s.isEmpty { show(end) }
        // B1: back to the start.
        let b1End = await walk(true, cap: WholeRead.cap, "b1")
        guard case .done(let back1) = b1End else { return await stopped(b1End, "b1") }
        clean = clean && lastWalkClean
        if let w = shown, back1 != w { leave("longer") }
        // An empty field (no text crossed either way): nothing to read twice, unless the proxy says there is text (a
        // host whose contexts and moves show nothing: refused, never read as empty; silent-failure review).
        if back1.isEmpty, first.isEmpty {
            leave("empty")
            return p.hasText ? await refuse("emptyHasText") : finish(.empty, "empty")
        }
        // R1 and FM: forward again, confirm the end. B2: the second walk back may not read more than the first.
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        guard let r1AtEnd = await returnMove(p, by: back1.count, end: end, start: t0, track: track) else {
            return await refuse("r1:timeUp")
        }
        let r1Waited = lastReturnWaited
        let fmEnd = await walk(false, cap: WholeRead.cap, "fm")
        guard case .done(let mid) = fmEnd else { return await stopped(fmEnd, "fm") }
        clean = clean && lastWalkClean
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        // F02c: the window the proxy showed was the whole field.
        // A return whose contexts needed time to show the end counts as a lag, as in the walks.
        if WholeRead.windowProof(window: shown, first: first, back1: back1, mid: mid,
                                 returnedAtEnd: r1AtEnd && !r1Waited, clean: clean) {
            let text = String(decoding: back1, as: UTF16.self)
            return finish(.text(text, isSelection: false), "window", back1)
        }
        let b2End = await walk(true, cap: back1.count, "b2")
        guard case .done(let back2) = b2End else { return await stopped(b2End, "b2") }
        // R2 and FE: the cursor goes to the end for Replace, and the end is confirmed once more.
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        guard await returnMove(p, by: back2.count, end: end, start: t0, track: track) != nil else {
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

    /// F02c, the CI latency checks: a field action's times in ms since its tap (the card's first text, the finished
    /// card), the call's own first update in ms after it started, and whether the speculative call was used
    /// (`used`, `none`, or `cancelled:<why>`). Numbers and fixed words only.
    static func logCall(first: Int, done: Int, api: Int, spec: String) {
        log.debug("call done first=\(first, privacy: .public) done=\(done, privacy: .public) api=\(api, privacy: .public) spec=\(spec, privacy: .public)")
    }

    /// F02c: how long Replace or Undo (`kind`) kept the keys waiting, in ms, and whether it was proven.
    static func logWrite(_ kind: String, keys: Int, held: Bool) {
        let ok = held ? 1 : 0
        log.debug("write \(kind, privacy: .public) keys=\(keys, privacy: .public) held=\(ok, privacy: .public)")
    }

    /// A step of this read or Replace took longer than WholeRead.slowStep to show: probes get a second look.
    private static var slowSeen = false

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
    /// `document`: the field's document identity (ProtlyHeight.document), nil when iOS gives none. A different one
    /// before the insert (the user tapped another field while the deletes showed) means no insert and not proven: the
    /// insert would land in the other field (tower review of f0533ae); the panel offers Copy original.
    static func replace(_ old: String, with new: String, _ p: UITextDocumentProxy,
                        document: () -> UUID? = { nil }) async -> Bool {
        let t0 = uptime()
        let doc0 = document()
        slowSeen = false
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
        let doc1 = document()
        // 1: another field now; 0: the same; -1: iOS gave no document.
        let focus = FieldGuard.focus(before: doc0, now: doc1).logValue
        if focus == 1 {
            let deletedNow = deleted
            log.debug("replace deleted=\(deletedNow, privacy: .public) emptyms=\(emptyMS, privacy: .public) focus=\(focus, privacy: .public) held=0")
            return false
        }
        p.insertText(new)
        let size = new.utf16.count
        let settle = t0 + WholeRead.replaceSettle(deletes: deleted, inserted: size)
        let deadline = t0 + WholeRead.replaceLimit(deletes: deleted, inserted: size)
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
            // An empty field in the contexts after the bound, quiet: the proxy may have stopped following the host (run
            // 8be8a93-218 etail: b=0 a=0 for 4.7 s while the field held the result). The check walk moves the cursor,
            // which refreshes the contexts, and decides; an empty field fails it as before.
            let blank = c.b.isEmpty && c.a.isEmpty && !new.isEmpty
            if uptime() >= settle, uptime() - quietFrom >= WholeRead.quiet, shows(new, c) || blank {
                shown = true
                break
            }
        }
        let quietMS = ms(since: t0)
        let c = ctx(p)
        let lb = c.before.count, la = c.after.count, ends = new.utf16.reversed().starts(with: c.before.reversed()) ? 1 : 0
        // The check moves the cursor: only in the field Replace wrote to (silent-failure review: the user may have
        // tapped another field while the strip said "Replacing the text…").
        // A local function, not a closure value: it captures the non-escaping `document` (Xcode refused the closure).
        func here() -> Bool { FieldGuard.focus(before: doc0, now: document()) != .other }
        var check = (ok: false, tries: 0, why: "gate")
        if !here() {
            check.why = "focus"
        } else if shown, !Task.isCancelled {
            check = await holds(new, p, here: here)
        }
        let held = check.ok, tries = check.tries, why = check.why
        let inserted = size, heldMS = ms(since: t0), ok = held ? 1 : 0, gate = shown ? 1 : 0
        let empty = emptied ? 1 : 0, seen = hostEvents - events0, cancelled = Task.isCancelled ? 1 : 0
        log.debug("replace deleted=\(deleted, privacy: .public) inserted=\(inserted, privacy: .public) sentms=\(sent, privacy: .public) emptyms=\(emptyMS, privacy: .public) empty=\(empty, privacy: .public) quietms=\(quietMS, privacy: .public) quiet=\(gate, privacy: .public) changes=\(changes, privacy: .public) lastch=\(lastChange, privacy: .public) events=\(seen, privacy: .public) firstev=\(firstEvent, privacy: .public) lastev=\(lastEvent, privacy: .public) b=\(lb, privacy: .public) a=\(la, privacy: .public) ends=\(ends, privacy: .public) heldms=\(heldMS, privacy: .public) held=\(ok, privacy: .public) tries=\(tries, privacy: .public) why=\(why, privacy: .public) focus=\(focus, privacy: .public) cancelled=\(cancelled, privacy: .public)")
        return held
    }

    /// The contexts show `new` as the whole field's end with the cursor there (an empty result: an empty field).
    private static func shows(_ new: String, _ c: Ctx) -> Bool {
        new.isEmpty ? c.b.isEmpty && c.a.isEmpty : FieldGuard.holdsResult(new, before: c.b, after: c.a)
    }

    /// The field is exactly `new` with the cursor at its end: a walk back reads exactly `new` to the start, a move
    /// forward by its length, and a walk forward reaches the end over `new`'s last units (a long move can land a few
    /// units short: probe runs 154, 155). Called once the host has had its time and the contexts show `new`'s end.
    /// Whatever the outcome, the cursor ends at the field's end (both reviews: the next key must not land mid-text).
    /// A second attempt (run 181: a walk that counted one unit too many and one that saw a change at the end, both
    /// while the field held exactly the result), but never after evidence of other text (a walk that read more than
    /// `new` or other units: old text left in the field), only once back at the end with the contexts showing `new`,
    /// and within the first half of the check's budget: both attempts share one 20 s budget (silent-failure review,
    /// round 2). `why`: what the first failed attempt found, for the log.
    private static func holds(_ new: String, _ p: UITextDocumentProxy,
                              here: () -> Bool) async -> (ok: Bool, tries: Int, why: String) {
        let units = Array(new.utf16)
        guard !units.isEmpty else { return (!p.hasText, 1, "-") }
        let t0 = uptime()
        var why = "-"
        for attempt in 1...2 {
            var cursor = CursorReturn()
            let track = Track { cursor = $0 }
            var evidence = false
            var found: String
            switch await walk(p, back: true, cap: units.count, tag: "v", start: t0, track: track, progress: {},
                              here: here) {
            case .done(let read) where read == units:
                guard here() else { return (false, attempt, "focus") }
                track.sending()
                let s = await step(p, by: units.count, wait: WholeRead.moveWait)
                track.landed(nil, s.c.b)  // may land short: the walk forward finds the end
                if !s.changed {
                    found = "jump"
                } else if case .done(let rest) = await walk(p, back: false, cap: units.count, tag: "ve", start: t0,
                                                            track: track, progress: {}, here: here) {
                    if Array(units.suffix(rest.count)) == rest { return (true, attempt, why) }
                    found = "veOther"
                    evidence = true
                } else {
                    found = "ve"
                }
            case .done:
                found = "vOther"
                evidence = true
            case .failed(let w):
                found = "v" + w.prefix(1).uppercased() + w.dropFirst()
                evidence = w == "tooLong"
            case .cancelled:
                found = "cancelled"
            }
            if attempt == 1 { why = found }
            guard here() else { return (false, attempt, "focus") }
            let atEnd = await backToEnd(p, cursor, cap: units.count + WholeRead.cap, here: here)
            guard attempt == 1, !evidence, atEnd, !Task.isCancelled, shows(new, ctx(p)),
                  uptime() - t0 < WholeRead.total / 2 else { return (false, attempt, why) }
        }
        return (false, 2, why)
    }

    /// After a check that did not prove the result: back to the field's end, by the record while it knows the way (one
    /// move, sent even after a hide), then, unless the keyboard was hidden, by a walk forward (its own budget: the
    /// cursor must get there). true when that walk reached the end.
    private static func backToEnd(_ p: UITextDocumentProxy, _ cursor: CursorReturn, cap: Int,
                                  here: () -> Bool) async -> Bool {
        let move = cursor.back(before: ctx(p).b)
        if move != 0 { _ = await step(p, by: move, wait: WholeRead.moveWait) }
        guard !Task.isCancelled, here() else { return false }
        if case .done = await walk(p, back: false, cap: cap, tag: "vr", start: uptime(), track: Track { _ in },
                                   progress: {}, here: here) {
            return true
        }
        return false
    }
}
