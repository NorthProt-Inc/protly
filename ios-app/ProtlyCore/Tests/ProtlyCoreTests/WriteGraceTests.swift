import XCTest
@testable import ProtlyCore

/// K1b, tower review of f0533ae (lower priority): a host callback soon after protly's own read or write is taken for
/// that read's or write's echo and ignored. Inside that window a change by the host or the user is not seen.
final class WriteGraceTests: XCTestCase {
    /// After a Replace the keyboard proved (its check walked the field and read exactly the result), the host had
    /// applied every edit: only the check's own last moves call back, within a second. A callback after that is a change,
    /// and Undo must end, however long the insert was (before: 1 s + 2.5 ms a unit, 11 s for 4000 units).
    func testAfterAProvenWriteOnlyASecondIsItsOwn() {
        XCTAssertTrue(WriteGrace.isOwn(elapsed: 0.8, inserted: 4000, proven: true))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 2, inserted: 4000, proven: true))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 1.01, inserted: 30, proven: true))
    }

    /// Read's Insert is not checked: the host may still be applying it, so its time grows with its length, as
    /// Replace's bound (WholeRead.replaceSettle's insert term).
    func testAnUnprovenInsertKeepsItsTime() {
        XCTAssertTrue(WriteGrace.isOwn(elapsed: 2, inserted: 4000, proven: false))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 11.1, inserted: 4000, proven: false))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 1.1, inserted: 0, proven: false))
    }

    /// After a read, the read's own last moves call back within the read's grace: later callbacks make Replace
    /// copy-only. What the window cannot show: an edit by the host inside it (documented, not detectable: no signal
    /// tells the read's own callbacks from a host's).
    func testAfterAReadTheGraceIsOneSecond() {
        XCTAssertTrue(WriteGrace.isReadEcho(elapsed: 0.9))
        XCTAssertFalse(WriteGrace.isReadEcho(elapsed: 1.1))
    }
}
