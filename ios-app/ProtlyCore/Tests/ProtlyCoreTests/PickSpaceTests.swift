import XCTest
@testable import ProtlyCore

/// K4E (docs/research/2026-11-17-keyboard-diagnosis.md, P4 case E): the space a pick from the bar types stands in for
/// the next space tap, as on Apple's keyboard (one tap after a pick adds nothing, two end the sentence).
final class PickSpaceTests: XCTestCase {
    typealias O = FieldWatch.Observed
    let window = FieldWatch.ownEditWindow
    /// Well past the own-edit window: the field is read as it is.
    let later = 10.0

    /// `the` picked after "hello " at t = 0, with `after` behind the cursor.
    private func picked(_ word: String = "the", after: String = "") -> PickSpace {
        var p = PickSpace()
        p.picked(word, after: after, at: 0)
        return p
    }

    private func tap(_ p: inout PickSpace, _ o: O, at now: Double? = nil, types: Bool = true) -> Bool {
        p.spaceReleased(types: types, o, now: now ?? later)
    }

    // MARK: The tap right after a pick

    func testOneTapRightAfterAPickIsTaken() {
        var p = picked()
        XCTAssertTrue(p.isWaiting)
        XCTAssertTrue(tap(&p, O(before: "hello the ")))
        XCTAssertFalse(p.isWaiting)
    }

    func testOnlyTheFirstTapIsTaken() {
        // The second tap types its space, and KeyboardKit's double-space check (clock started by the first) ends the
        // sentence: `the. `.
        var p = picked()
        XCTAssertTrue(tap(&p, O(before: "the ")))
        XCTAssertFalse(tap(&p, O(before: "the ")))
    }

    func testNoPickTakesNothing() {
        var p = PickSpace()
        XCTAssertFalse(p.isWaiting)
        XCTAssertFalse(tap(&p, O(before: "the ")))
    }

    func testTheTapIsTakenHoweverLongAfterThePick() {
        // Nothing but the field ends the pick: no clock. The double-space window starts at this tap (KeyboardKit's).
        var p = picked()
        XCTAssertTrue(tap(&p, O(before: "the "), at: 600))
    }

    func testAKoreanPick() {
        var p = picked("안녕")
        XCTAssertTrue(tap(&p, O(before: "오늘 안녕 ")))
    }

    func testAKoreanPickReadBackDecomposed() {
        var p = picked("안녕")
        XCTAssertTrue(tap(&p, O(before: "안녕 ".decomposedStringWithCanonicalMapping)))
    }

    func testANoBreakSpaceCountsAsThePicksSpace() {
        // WebKit stores a space typed at the end of a contenteditable field as U+00A0.
        var p = picked()
        XCTAssertTrue(tap(&p, O(before: "hello the\u{00A0}")))
    }

    func testAPickBeforeAWord() {
        var p = picked(after: "world")
        XCTAssertTrue(tap(&p, O(before: "the ", after: "world")))
    }

    func testANewPickReplacesTheLast() {
        var p = picked()
        p.picked("and", after: "", at: 1)
        XCTAssertTrue(tap(&p, O(before: "the and ")))
    }

    // MARK: What ends the pick

    func testAnyOtherKeyEndsIt() {
        var p = picked()
        p.end()
        XCTAssertFalse(p.isWaiting)
        XCTAssertFalse(tap(&p, O(before: "the ")))
    }

    func testATrackpadReleaseEndsIt() {
        // A hold of 0.4 s or more turns space into the trackpad: that release types nothing, and the next tap types.
        var p = picked()
        XCTAssertFalse(tap(&p, O(before: "the "), types: false))
        XCTAssertFalse(p.isWaiting)
        XCTAssertFalse(tap(&p, O(before: "the ")))
    }

    func testTheHostClearingTheFieldEndsIt() {
        // A chat app sent the message and cleared the field with the keyboard still up.
        var p = picked()
        p.noticed(O(before: ""), now: later)
        XCTAssertFalse(p.isWaiting)
        XCTAssertFalse(tap(&p, O(before: "")))
    }

    func testACursorMoveEndsIt() {
        var p = picked()
        p.noticed(O(before: "hello the", after: " "), now: later)  // one character back
        XCTAssertFalse(p.isWaiting)
        var q = picked()
        q.noticed(O(before: "hello ", after: "the "), now: later)  // a tap in front of the word
        XCTAssertFalse(q.isWaiting)
        var r = picked(after: "world")
        r.noticed(O(before: "the ", after: ""), now: later)  // the text after the cursor changed
        XCTAssertFalse(r.isWaiting)
    }

    func testAnEditOfThePickedWordEndsIt() {
        var p = picked()
        p.noticed(O(before: "hello then "), now: later)
        XCTAssertFalse(p.isWaiting)
    }

    func testASelectionEndsItEvenRightAfterThePick() {
        var p = picked()
        p.noticed(O(before: "hello ", selected: "the "), now: 0.01)
        XCTAssertFalse(p.isWaiting)
        var q = picked()
        XCTAssertFalse(tap(&q, O(before: "the ", selected: "the"), at: 0.01))
    }

    func testTheFieldStillShowingThePickKeepsIt() {
        // The host's callbacks for the pick's own writes arrive late (50-70 ms) and show the field as the pick left it.
        var p = picked()
        p.noticed(O(before: "hello the "), now: 0.07)
        p.noticed(O(before: "hello the "), now: later)
        XCTAssertTrue(p.isWaiting)
        XCTAssertTrue(tap(&p, O(before: "hello the ")))
    }

    func testAContextLaggingBehindThePickKeepsItInTheOwnEditWindow() {
        // A web view may still show the word before the pick, or the word without its space.
        var p = picked()
        p.noticed(O(before: "hello teh"), now: 0.05)
        p.noticed(O(before: "hello the"), now: window * 0.9)
        XCTAssertTrue(p.isWaiting)
        XCTAssertTrue(tap(&p, O(before: "hello the "), at: 1))
        var q = picked()
        XCTAssertTrue(tap(&q, O(before: "hello the"), at: 0.1), "a fast tap on a lagging context is still taken")
    }

    func testAMismatchAfterTheOwnEditWindowEndsIt() {
        var p = picked()
        p.noticed(O(before: "hello teh"), now: window)
        XCTAssertFalse(p.isWaiting)
        var q = picked()
        XCTAssertFalse(tap(&q, O(before: "hello the"), at: window + 0.01))
    }

    func testAClockThatWentBackIsNotTheOwnEditWindow() {
        var p = PickSpace()
        p.picked("the", after: "", at: 5)
        p.noticed(O(before: ""), now: 4.9)
        XCTAssertFalse(p.isWaiting)
    }

    func testCallbacksWithoutAPickChangeNothing() {
        var p = PickSpace()
        p.noticed(O(before: "the "), now: later)
        XCTAssertEqual(p, PickSpace())
    }
}
