import XCTest
@testable import ProtlyCore

/// keyboard-ui 003 (P6), K1b: Cancel puts the cursor back where it was before the whole-field read moved it. The read
/// walks forward and back, so the record is the cursor's offset from where the user had it, while it is known.
final class CursorReturnTests: XCTestCase {
    private func step(_ c: inout CursorReturn, _ moved: Int?, before: String) {
        c.sending()
        c.landed(moved: moved, before: before)
    }

    func testTheOffsetSumsTheSettledSteps() {
        var c = CursorReturn()
        c.begin()
        step(&c, 40, before: "a")
        step(&c, 25, before: "b")
        step(&c, -60, before: "c")
        XCTAssertEqual(c.back(before: "c"), -5)
    }

    func testAStepOnItsWayCountsOnlyOnceSettled() {
        var c = CursorReturn()
        c.begin()
        step(&c, 10, before: "x")
        c.sending()
        XCTAssertTrue(c.isMoving)
        c.landed(moved: 0, before: "x")
        XCTAssertFalse(c.isMoving)
        XCTAssertEqual(c.back(before: "x"), -10)
    }

    /// A step whose move cannot be named (a bad step, a phantom): the cursor stays where it is on Cancel.
    func testAnUnknownMoveStopsTheReturn() {
        var c = CursorReturn()
        c.begin()
        step(&c, 10, before: "x")
        step(&c, nil, before: "y")
        step(&c, 5, before: "z")
        XCTAssertEqual(c.back(before: "z"), 0)
        XCTAssertFalse(c.isKnown)
    }

    /// An accepted read ends at the field's end, which the walks confirmed: the cursor is then the first forward walk's
    /// length past where the user had it, whatever happened in between (a phantom at the start included).
    func testAConfirmedEndMakesThePositionKnownAgain() {
        var c = CursorReturn()
        c.begin()
        step(&c, 30, before: "end")
        step(&c, nil, before: "")
        c.confirmEnd(fromOrigin: 30, before: "end")
        XCTAssertEqual(c.back(before: "end"), -30)
    }

    /// The field changed after the read: typed at the end, or the window no longer agrees with where the read left
    /// the cursor. A window that only grew or shrank in front still agrees.
    func testTheReturnNeedsTheSameBeforeContext() {
        var c = CursorReturn()
        c.begin()
        step(&c, 12, before: "the end.")
        XCTAssertEqual(c.back(before: "the end.x"), 0)
        XCTAssertEqual(c.back(before: "end."), -12)
        XCTAssertEqual(c.back(before: "and so the end."), -12)
        XCTAssertEqual(c.back(before: ""), 0, "an empty context agrees with everything: only with another empty one")
        step(&c, -20, before: "")
        XCTAssertEqual(c.back(before: ""), 8, "stopped at the start")
        XCTAssertEqual(c.back(before: "x"), 0)
    }

    func testNothingMovedOrClearedMeansNothingToDo() {
        var c = CursorReturn()
        XCTAssertEqual(c.back(before: ""), 0)
        c.begin()
        step(&c, 0, before: "a")
        XCTAssertEqual(c.back(before: "a"), 0)
        step(&c, 3, before: "abc")
        c.clear()
        XCTAssertEqual(c.back(before: "abc"), 0)
        XCTAssertFalse(c.isMoving)
    }

    func testBeginStartsAFreshRecord() {
        var c = CursorReturn()
        c.begin()
        step(&c, 7, before: "abc")
        c.begin()
        XCTAssertEqual(c.back(before: "abc"), 0)
    }
}
