import ProtlyCore
import UIKit
import os

/// One-pass whole-field read and synchronous Replace through the text document proxy. WholeRead holds the pure rules;
/// this file only drives the proxy and applies WholeRead.accept.
@MainActor
enum FieldText {
    /// Lengths, line-feed counts, hashes, reasons and timings only, never text (KeyboardSourceRulesTests).
    private static let log = Logger(subsystem: "com.northprot.protly", category: "read")

    /// The read's record of the cursor (CursorReturn). Every change goes to `report` at once for Cancel.
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
        /// Select all was collapsed: the user's place is now the collapse point (the selection cannot come back).
        func restart() { cursor.begin(); report(cursor) }
    }

    enum Outcome {
        /// The whole field (cursor at its end), or a partial selection (K1a: its card only copies).
        case text(String, isSelection: Bool)
        /// Nothing but whitespace: the protly key reads the clipboard.
        case empty
        /// Not accepted whole: never sent. The reason goes to the log only.
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
    /// in a row agree.
    private static func step(_ p: UITextDocumentProxy, by k: Int, wait: TimeInterval) async -> (changed: Bool, c: Ctx, seen: Int) {
        let c0 = ctx(p)
        p.adjustTextPosition(byCharacterOffset: k)  // UTF-16 units on native hosts; characters on the web
        return await watch(p, from: c0, wait: wait)
    }

    /// Polls until the contexts differ from `c0` and settle, or `wait` passes.
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
        let last = ctx(p)
        return (last != c0, last, last != c0 ? ms(since: sent) : -1)
    }

    private enum WalkEnd {
        case done([UInt16])
        case failed(String)
        case cancelled
    }

    /// The longest a step can take: its wait, the settle polls and a margin for the main thread.
    private static func stepCost(_ wait: TimeInterval) -> TimeInterval {
        wait + Double(WholeRead.settlePolls + 1) * WholeRead.poll
    }

    /// One walk to the end (`back` false) or the start (`back` true). Stops on the first sign of lag, blank, misfit
    /// or timeout; `singleStep` runs only one step (FM's +1 probe at the end).
    private static func walk(_ p: UITextDocumentProxy, back: Bool, tag: String, start t0: TimeInterval,
                             track: Track, progress: () -> Void, singleStep: Bool = false) async -> WalkEnd {
        var bw = BackWalk()
        var fw = ForwardWalk()
        var steps = 0, firstMS = -1
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
            let count = units.count, lf = WholeRead.lineFeeds(units), took = ms(since: w0)
            log.debug("read walk \(tag, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) reason=\(reason, privacy: .public) steps=\(steps, privacy: .public) ms=\(took, privacy: .public) first=\(firstMS, privacy: .public)")
            return e
        }
        func logStep(_ why: String, k: Int, from c: Ctx, to s: (changed: Bool, c: Ctx, seen: Int), ms took: Int) {
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
                // On an empty before-context wait emptyWait once before probing -1; if text comes back, the host lagged.
                guard fits(WholeRead.emptyWait + WholeRead.probeWait) else { return end(.failed("timeUp")) }
                let e0 = uptime()
                while uptime() - e0 < WholeRead.emptyWait, ctx(p).before.isEmpty { await pause() }
                c = ctx(p)
                if Task.isCancelled { return end(.cancelled) }
                if !c.before.isEmpty { return end(.failed("blank")) }
            }
            let probing = back ? c.before.isEmpty : c.after.isEmpty
            let wait = probing ? WholeRead.probeWait : WholeRead.moveWait
            guard fits(wait) else { return end(.failed("timeUp")) }
            if Task.isCancelled { return end(.cancelled) }
            let k = back ? bw.plan(before: c.before, after: c.after) : fw.plan(before: c.before, after: c.after)
            steps += 1
            track.sending()
            let s0 = uptime()
            let s = await step(p, by: back ? -k : k, wait: wait)
            if steps == 1 { firstMS = ms(since: s0) }
            let r = back ? bw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
                : fw.landed(changed: s.changed, before: s.c.before, after: s.c.after)
            let pr = probing ? 1 : 0, ch = s.changed ? 1 : 0, tot = ms(since: s0), seenMS = s.seen
            log.debug("read st \(tag, privacy: .public) s=\(steps, privacy: .public) k=\(k, privacy: .public) pr=\(pr, privacy: .public) ch=\(ch, privacy: .public) seen=\(seenMS, privacy: .public) tot=\(tot, privacy: .public)")
            if case .failed(let why, _) = r { logStep(why, k: k, from: c, to: s, ms: tot) }
            switch r {
            case .moved(let d):
                track.landed(d, s.c.b)
                if singleStep { return end(.done(back ? bw.units : fw.units)) }
            case .done:
                if back { track.landed(0, s.c.b) } else { track.reachedEnd(s.c.b) }
                return end(.done(back ? bw.units : fw.units))
            case .failed(let why, let moved):
                track.landed(moved, s.c.b)
                return end(.failed(why))
            }
        }
    }

    /// R1: one move forward by B1's length; the contexts must show the end again immediately (no extra wait).
    private static func returnMove(_ p: UITextDocumentProxy, by n: Int, end: Ctx, start t0: TimeInterval,
                                   track: Track) async -> WholeRead.ReturnOutcome {
        guard n > 0 else { return .notAtEnd }
        guard WholeRead.canStart(elapsed: uptime() - t0, wait: stepCost(WholeRead.moveWait)) else { return .timeUp }
        track.sending()
        let s = await step(p, by: n, wait: WholeRead.moveWait)
        let atEnd = WholeRead.showsEnd(changed: s.changed, before: s.c.before, after: s.c.after, endBefore: end.before)
        track.landed(atEnd ? n : nil, s.c.b)
        return atEnd ? .atEnd : .notAtEnd
    }

    /// One-pass whole-field read (F, B1, R1, FM), decided purely by WholeRead.accept.
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
            log.debug("read done outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) units=\(count, privacy: .public) lf=\(lf, privacy: .public) h=\(hash, privacy: .public) ms=\(took, privacy: .public) known=\(known, privacy: .public)")
            return o
        }
        /// When a step since the field's end lost the cursor position, walk back to the end within the same budget so
        /// the keyboard can put the cursor back.
        func refuse(_ reason: String) async -> Outcome {
            if !track.cursor.isKnown, track.cursor.hasEnd, !Task.isCancelled {
                if case .cancelled = await walk(p, back: false, tag: "fr", start: t0, track: track, progress: progress) {
                    return finish(.cancelled, "cancelled")
                }
            }
            return finish(.refused, reason)
        }
        let fromSelection = !c0.s.isEmpty
        if fromSelection {
            // K1a: a partial selection with context on either side is its own copy-only card.
            // Select all (no context on either side): collapse with +1 and read; text after it means refuse.
            guard c0.b.isEmpty, c0.a.isEmpty else { return finish(.text(c0.s, isSelection: true), "selection") }
            track.sending()
            let s = await step(p, by: 1, wait: WholeRead.moveWait)
            track.restart()
            if Task.isCancelled { return finish(.cancelled, "cancelled") }
            guard s.changed, s.c.s.isEmpty else { return finish(.refused, "collapse") }
        }
        var pass = WholeRead.OnePass(first: .failed("unrun"), fromSelection: fromSelection)
        switch await walk(p, back: false, tag: "f", start: t0, track: track, progress: progress) {
        case .cancelled: return finish(.cancelled, "cancelled")
        case .failed(let why): pass.first = .failed(why)
        case .done(let first):
            pass.first = .done(first)
            if !fromSelection || first.isEmpty {
                let end = ctx(p)
                switch await walk(p, back: true, tag: "b1", start: t0, track: track, progress: progress) {
                case .cancelled: return finish(.cancelled, "cancelled")
                case .failed(let why): pass.back = .failed(why)
                case .done(let back1):
                    pass.back = .done(back1)
                    if !back1.isEmpty || !first.isEmpty {
                        if Task.isCancelled { return finish(.cancelled, "cancelled") }
                        let r1 = await returnMove(p, by: back1.count, end: end, start: t0, track: track)
                        pass.returned = r1
                        if r1 == .atEnd {
                            switch await walk(p, back: false, tag: "fm", start: t0, track: track, progress: progress,
                                              singleStep: true) {
                            case .cancelled: return finish(.cancelled, "cancelled")
                            case .failed(let why): pass.endProbe = .failed(why)
                            case .done(let mid): pass.endProbe = .done(mid)
                            }
                        }
                    }
                }
            }
        }
        if Task.isCancelled { return finish(.cancelled, "cancelled") }
        pass.hasText = p.hasText
        switch WholeRead.accept(pass) {
        case .accept(let units):
            return finish(.text(String(decoding: units, as: UTF16.self), isSelection: false), "-", units)
        case .empty:
            return finish(.empty, "empty")
        case .refuse(let why):
            return await refuse(why)
        }
    }

    /// Cancel or refusal (P6): move the cursor back by `move` in one step.
    static func restore(_ move: Int, known: Bool, _ p: UITextDocumentProxy) {
        let units = abs(move), position = known ? 1 : 0
        log.debug("read restore units=\(units, privacy: .public) known=\(position, privacy: .public)")
        guard move != 0 else { return }
        p.adjustTextPosition(byCharacterOffset: move)
    }

    /// Call timing for CI logs (recorded, not gated). Numbers and fixed words only.
    static func logCall(first: Int, done: Int, api: Int, spec: String) {
        log.debug("call done first=\(first, privacy: .public) done=\(done, privacy: .public) api=\(api, privacy: .public) spec=\(spec, privacy: .public)")
    }

    /// Replace or Undo keys-wait in ms (gated under 100 ms in CI).
    static func logWrite(_ kind: String, keys: Int) {
        log.debug("write \(kind, privacy: .public) keys=\(keys, privacy: .public)")
    }

    /// Replace what `read` returned (cursor at the end) with `new` in one synchronous block: no await, no timer, no
    /// check walk; the keys never wait and focus cannot change between the deletes and the insert (Codex bug 4).
    static func replace(_ old: String, with new: String, _ p: UITextDocumentProxy) {
        for _ in old { p.deleteBackward() }  // one Character per call
        p.insertText(new)
    }
}
