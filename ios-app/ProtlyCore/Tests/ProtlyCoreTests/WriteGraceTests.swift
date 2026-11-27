import XCTest
@testable import ProtlyCore

/// A host callback soon after protly's own read or write is taken for that read's or write's echo; a new field read
/// also waits out `replaceSettle` after a write.
final class WriteGraceTests: XCTestCase {
    func testWriteEchoUsesReplaceSettle() {
        // 335 deletes + 26 inserted: replaceSettle = 1.5 + 1.34 + 0.065 = 2.905 s.
        XCTAssertTrue(WriteGrace.isOwn(elapsed: 2.0, deletes: 335, inserted: 26))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 3.0, deletes: 335, inserted: 26))
        // Read's Insert (0 deletes): 1.5 + 0.0025 * inserted.
        XCTAssertTrue(WriteGrace.isOwn(elapsed: 1.5, deletes: 0, inserted: 0))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 1.6, deletes: 0, inserted: 0))
        XCTAssertTrue(WriteGrace.isOwn(elapsed: 2.0, deletes: 0, inserted: 400))
        XCTAssertFalse(WriteGrace.isOwn(elapsed: 2.6, deletes: 0, inserted: 400))
    }

    func testAfterAReadTheGraceIsOneSecond() {
        XCTAssertTrue(WriteGrace.isReadEcho(elapsed: 0.9))
        XCTAssertFalse(WriteGrace.isReadEcho(elapsed: 1.1))
    }
}
