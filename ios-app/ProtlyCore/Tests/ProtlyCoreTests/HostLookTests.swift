import XCTest
@testable import ProtlyCore

/// K2 (docs/research/2026-11-17-keyboard-diagnosis.md, P2): iOS draws the keyboard's glass flush with Protly's view or
/// 17 pt above it, by the host's history. The keyboard pins its view so the band above the bar is Apple's in both.
/// Times are seconds on the keyboard's monotonic clock; the gaps are the simulator's (runs 159-178).
final class HostLookTests: XCTestCase {
    let content = 257.0

    /// A controller that loads at `at` and appears right after, in `document`.
    @discardableResult
    private func present(_ look: inout HostLook, at: Double, document: UUID?) -> HostLook.Document {
        look.loaded(at: at)
        return look.appeared(document: document, at: at + 0.03)
    }

    /// The host goes to the background with the keyboard up and comes back with it: the old controller disappears
    /// 1 s after the resign notice, the new one loads 2 s later and the became-active notice comes 0.3 s after that.
    private func appSwitch(_ look: inout HostLook, at t: Double, document: UUID?) {
        look.hostWillResignActive(at: t)
        look.disappeared(document: document, at: t + 1)
        present(&look, at: t + 3, document: nil)  // iOS gives no document at will appear on this path (run 177)
        look.hostBecameActive(at: t + 3.3)
    }

    /// A fresh host with the keyboard up, then an app switch: the margin.
    private func afterAppSwitch(_ doc: UUID = UUID()) -> HostLook {
        var look = HostLook()
        present(&look, at: 0, document: doc)
        appSwitch(&look, at: 10, document: doc)
        XCTAssertTrue(look.margin)
        return look
    }

    // MARK: The pin

    func testNoMarginPinsTheContentHeight() {
        let look = HostLook()
        XCTAssertFalse(look.margin)
        XCTAssertEqual(look.pin(content: content), 257)
    }

    func testTheMarginComesOffThePin() {
        XCTAssertEqual(afterAppSwitch().pin(content: content), 240)
        XCTAssertEqual(HostLook.hostTopMargin, 17)
    }

    // MARK: The host's return (rule 2)

    func testAReturnWithTheKeyboardUpMeansTheMargin() {
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 10)
        look.disappeared(document: nil, at: 11.2)
        XCTAssertFalse(look.margin)
        present(&look, at: 14, document: nil)
        XCTAssertFalse(look.margin, "257 until the notice")
        look.hostBecameActive(at: 14.4)
        XCTAssertTrue(look.margin)
    }

    func testAReturnJustBeforeLoadingMeansTheMargin() {
        // Run 59: the notice came 32 ms before the new controller loaded.
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 10)
        look.disappeared(document: nil, at: 11)
        look.hostBecameActive(at: 13.968)
        present(&look, at: 14, document: nil)
        XCTAssertTrue(look.margin)
    }

    func testAReturnLongBeforeLoadingDoesNotCount() {
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 10)
        look.disappeared(document: nil, at: 11)
        look.hostBecameActive(at: 13)
        present(&look, at: 13 + HostLook.earlyWindow, document: nil)
        XCTAssertFalse(look.margin)
    }

    func testALateNoticeDoesNotCount() {
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 10)
        look.disappeared(document: nil, at: 11)
        present(&look, at: 14, document: nil)
        look.hostBecameActive(at: 14 + HostLook.freshWindow)
        XCTAssertFalse(look.margin)
    }

    func testBecameActiveWithoutLeavingChangesNothing() {
        // Control Center, an alert, Face ID or a notification reply over a live keyboard (resign, no disappear), and
        // a cold launch that opens the keyboard at once (no resign at all): iOS keeps the look it had.
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 0.5)
        look.hostBecameActive(at: 1)
        XCTAssertFalse(look.margin)
        var cold = HostLook()
        present(&cold, at: 0, document: UUID())
        cold.hostBecameActive(at: 0.3)
        XCTAssertFalse(cold.margin)
    }

    func testAHideLongAfterAResignIsNotLeaving() {
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 1)
        look.hostBecameActive(at: 2)
        look.disappeared(document: nil, at: 1 + HostLook.resignWindow)
        present(&look, at: 20, document: UUID())
        look.hostBecameActive(at: 20.3)
        XCTAssertFalse(look.margin)
    }

    func testAControllerShownAgainLaterGetsANewWindow() {
        // A controller iOS shows again after `freshWindow` (not seen on the simulator: every presentation there made a
        // new controller) counts as attached by the host's return, as a new one would.
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostWillResignActive(at: 10)
        look.disappeared(document: nil, at: 11)
        look.appeared(document: nil, at: 30)
        look.hostBecameActive(at: 30.3)
        XCTAssertTrue(look.margin)
    }

    // MARK: Hide and show keep the look (rule 3)

    func testHideAndShowKeepTheMargin() {
        var look = afterAppSwitch()
        for i in 1...5 {
            look.disappeared(document: nil, at: Double(i) * 10 + 15)  // a hide: no document at disappear (run 177)
            present(&look, at: Double(i) * 10 + 20, document: UUID())
            XCTAssertTrue(look.margin, "show \(i)")
        }
    }

    func testALongHideClearsTheMargin() {
        // iOS drops its margin when the host goes to the background with the keyboard hidden (run 183, hb-r2 5/5;
        // and a relaunch, hb-r1 5/5), and no notice reaches the keyboard then. Hidden for `hiddenExpiry` or longer
        // counts as that (a guess: on the simulator a hide and show took about 7 s from disappear to load).
        var look = afterAppSwitch()
        look.disappeared(document: nil, at: 20)
        present(&look, at: 20 + HostLook.hiddenExpiry - 0.1, document: UUID())
        XCTAssertTrue(look.margin, "just under the expiry")
        look.disappeared(document: nil, at: 40)
        present(&look, at: 40 + HostLook.hiddenExpiry, document: UUID())
        XCTAssertFalse(look.margin)
    }

    func testAnAppSwitchAfterALongHideStillMeansTheMargin() {
        var look = afterAppSwitch()
        look.disappeared(document: nil, at: 20)
        present(&look, at: 50, document: UUID())
        XCTAssertFalse(look.margin)
        appSwitch(&look, at: 70, document: nil)
        XCTAssertTrue(look.margin)
    }

    func testAControllerShownAgainAfterALongHideHasNoMargin() {
        var look = afterAppSwitch()
        look.disappeared(document: nil, at: 20)
        look.appeared(document: UUID(), at: 20 + HostLook.hiddenExpiry)
        XCTAssertFalse(look.margin)
    }

    func testHideAndShowKeepNoMargin() {
        var look = HostLook()
        for i in 0...5 {
            if i > 0 { look.disappeared(document: nil, at: Double(i) * 10 - 5) }
            present(&look, at: Double(i) * 10, document: UUID())
            XCTAssertFalse(look.margin, "show \(i)")
        }
    }

    // MARK: Leaving with the keyboard up (rule 1) and a new host (rule 1b)

    func testLeavingWithTheKeyboardUpClearsTheMargin() {
        // The host goes to the background with the keyboard up and is killed there; the keyboard's process lives on
        // (one process across relaunches on the simulator). The relaunch shows no margin.
        let doc = UUID()
        var look = afterAppSwitch(doc)
        look.hostWillResignActive(at: 30)
        look.disappeared(document: doc, at: 31)
        XCTAssertFalse(look.margin)
        present(&look, at: 60, document: UUID())
        XCTAssertFalse(look.margin)
    }

    func testATerminatedHostShowsNoMargin() {
        // The host was terminated with the keyboard up: its controller never got viewDidDisappear.
        var look = afterAppSwitch()
        present(&look, at: 40, document: UUID())
        XCTAssertFalse(look.margin)
    }

    func testAControllerThatNeverAppearedIsNotATerminatedHost() {
        // iOS sometimes loads a controller and shows another keyboard instead (runs 159-169).
        var look = afterAppSwitch()
        look.disappeared(document: nil, at: 20)
        look.loaded(at: 22)
        present(&look, at: 25, document: UUID())
        XCTAssertTrue(look.margin)
    }

    func testAShownAgainControllerThatGoesWithItsHostIsATerminatedHost() {
        var look = afterAppSwitch()
        look.disappeared(document: nil, at: 20)
        look.appeared(document: UUID(), at: 25)  // shown again, then the host is terminated with it up
        XCTAssertTrue(look.margin)
        present(&look, at: 28, document: UUID())
        XCTAssertFalse(look.margin)
    }

    // MARK: Back from another keyboard (rule 4)

    func testBackFromAnotherKeyboardShowsNoMargin() {
        // The field kept its document while Emoji was up; iOS draws no margin when Protly comes back (runs 177, 178).
        let doc = UUID()
        var look = afterAppSwitch(doc)
        look.disappeared(document: doc, at: 20)
        XCTAssertEqual(present(&look, at: 25, document: doc), .same)
        XCTAssertFalse(look.margin)
    }

    func testAnotherDocumentIsHideAndShow() {
        var look = afterAppSwitch()
        look.disappeared(document: UUID(), at: 20)
        XCTAssertEqual(present(&look, at: 25, document: UUID()), .other)
        XCTAssertTrue(look.margin)
    }

    func testAnUnknownDocumentChangesNothing() {
        let doc = UUID()
        var look = afterAppSwitch(doc)
        look.disappeared(document: doc, at: 20)
        XCTAssertEqual(present(&look, at: 25, document: nil), .none)
        XCTAssertTrue(look.margin)
        var other = afterAppSwitch(doc)
        other.disappeared(document: nil, at: 20)
        XCTAssertEqual(present(&other, at: 25, document: doc), .other)
        XCTAssertTrue(other.margin)
    }

    func testAReturnFromLeavingInTheSameDocumentKeepsTheMargin() {
        // The field keeps its document across the background. If iOS gave it at will appear on this path, the return
        // still wins over rule 4, with the notice after the load or just before it.
        let doc = UUID()
        var late = HostLook()
        present(&late, at: 0, document: doc)
        late.hostWillResignActive(at: 10)
        late.disappeared(document: doc, at: 11)
        present(&late, at: 14, document: doc)
        XCTAssertFalse(late.margin)
        late.hostBecameActive(at: 14.3)
        XCTAssertTrue(late.margin)

        var early = afterAppSwitch(doc)
        early.hostWillResignActive(at: 30)
        early.disappeared(document: doc, at: 31)
        early.hostBecameActive(at: 33.97)
        present(&early, at: 34, document: doc)
        XCTAssertTrue(early.margin)
    }
}
