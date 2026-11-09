import XCTest
@testable import ProtlyCore

// Plan 2026-11-08 Part B #2: Deep re-runs a finished or cut-off Translate or Polish card on the same model at effort
// high (ActionProfile.deep). What is offered where, and what Deep and Retry send, is decided here; the keyboard only
// draws the button and runs the call.
final class DeepTests: XCTestCase {
    /// On a finished card, and with a cut-off reply (on the card or on the strip). Never for Read clipboard, never
    /// while the text streams, never after any other error.
    func testDeepIsOfferedOnAFinishedOrCutOffCardOnly() {
        for mode in [ActionMode.out, .fix] {
            XCTAssertTrue(ActionProfile.offersDeep(mode, done: true, error: nil), "\(mode) done")
            XCTAssertTrue(ActionProfile.offersDeep(mode, done: false, error: ActionError(.truncated)), "\(mode) cut off")
            XCTAssertFalse(ActionProfile.offersDeep(mode, done: false, error: nil), "\(mode) streaming")
            for kind in [ActionError.Kind.network, .timeout, .overloaded, .refused, .parse, .tooLong, .auth, .notesOnly] {
                XCTAssertFalse(ActionProfile.offersDeep(mode, done: false, error: ActionError(kind)), "\(mode) \(kind)")
            }
        }
        XCTAssertFalse(ActionProfile.offersDeep(.in, done: true, error: nil))
        XCTAssertFalse(ActionProfile.offersDeep(.in, done: false, error: ActionError(.truncated)))
    }

    /// Deep runs the same mode on what the field read returned, at effort high; the selection flag stays, so Replace
    /// puts the deep result where the first one would have gone. Read clipboard has no Deep.
    func testDeepRerunsTheSameModeOnTheOriginal() {
        let first = ActionCall(mode: .out, text: "오늘 고마워 [짧게]", original: "오늘 고마워 [짧게]", isSelection: true)
        XCTAssertEqual(first.profile, .normal)
        XCTAssertEqual(first.deep, ActionCall(mode: .out, text: "오늘 고마워 [짧게]", original: "오늘 고마워 [짧게]",
                                              isSelection: true, profile: .deep))
        let fix = ActionCall(mode: .fix, text: "teh cat", original: "teh cat", isSelection: false)
        XCTAssertEqual(fix.deep?.mode, .fix)
        XCTAssertEqual(fix.deep?.text, "teh cat")
        XCTAssertEqual(fix.deep?.isSelection, false)
        XCTAssertEqual(fix.deep?.profile, .deep)
        // The original, not the text sent: they differ only if a call ever sends a changed text.
        XCTAssertEqual(ActionCall(mode: .out, text: "sent", original: "read", isSelection: false).deep?.text, "read")
        // Deep again on a deep card is the same deep call.
        XCTAssertEqual(fix.deep?.deep, fix.deep)
        XCTAssertNil(ActionCall(mode: .in, text: "someone's text", original: "", isSelection: false).deep)
        XCTAssertNil(ActionCall(mode: .in, text: "x", original: "", isSelection: false, profile: .deep).deep)
    }

    /// Retry of a failed deep call is deep again, on the same text. A normal call has no such retry: the keyboard
    /// starts it over as before (the field read again, or Read's own text).
    func testRetryOfADeepCallStaysDeep() {
        let deep = ActionCall(mode: .fix, text: "teh cat", original: "teh cat", isSelection: false, profile: .deep)
        XCTAssertEqual(deep.deepRetry, deep)
        XCTAssertNil(ActionCall(mode: .fix, text: "teh cat", original: "teh cat", isSelection: false).deepRetry)
        XCTAssertNil(ActionCall(mode: .in, text: "x", original: "", isSelection: false).deepRetry)
    }

    /// The cut-off line names the way out, as the extension's does (src/ui/errors.js).
    func testTheCutOffLineOffersDeep() {
        XCTAssertEqual(ActionError(.truncated).message, "The reply was cut off. Try Deep or a shorter text.")
        XCTAssertFalse(ActionError(.truncated).canRetry)
    }
}
