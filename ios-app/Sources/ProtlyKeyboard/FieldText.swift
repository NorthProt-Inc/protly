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
        // A whitespace-only field counts as empty, as in the bar: the protly key reads the clipboard.
        guard let before = proxy.documentContextBeforeInput,
              !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (before, false)
    }

    /// 20 ms that a cancel does not cut short (Task.sleep would end at once).
    private static func pause() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { c.resume() }
        }
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
