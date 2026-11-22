import XCTest
@testable import ProtlyCore

/// K2 (docs/research/2026-11-17-keyboard-diagnosis.md, P2): iOS draws the keyboard's glass flush with Protly's view or
/// 17 pt above it, by the host's history. The keyboard pins its view so the band above the bar is Apple's in both.
final class HostLookTests: XCTestCase {
    let content = 257.0

    /// A controller that loads at `at` and appears right after, in `document`.
    private func present(_ look: inout HostLook, at: Double, document: UUID) {
        look.loaded(at: at)
        look.appeared(document: document, at: at + 0.1)
    }

    // MARK: The pin

    func testNoMarginPinsTheContentHeight() {
        let look = HostLook()
        XCTAssertFalse(look.margin)
        XCTAssertEqual(look.pin(content: content), 257)
    }

    func testTheMarginComesOffThePin() {
        var look = HostLook()
        look.loaded(at: 0)
        look.hostBecameActive(at: 0.3)
        XCTAssertTrue(look.margin)
        XCTAssertEqual(look.pin(content: content), 240)
        XCTAssertEqual(HostLook.hostTopMargin, 17)
    }

    // MARK: The host's return (rule 2)

    func testAReturnSoonAfterLoadingMeansTheMargin() {
        // Runs 159-168: NSExtensionHostDidBecomeActive came 0.22-0.41 s after the new controller loaded.
        var look = HostLook()
        look.loaded(at: 10)
        look.appeared(document: UUID(), at: 10.1)
        look.hostBecameActive(at: 10.4)
        XCTAssertTrue(look.margin)
    }

    func testAReturnOverAnOldControllerChangesNothing() {
        // Control Center, an alert or Face ID over a live keyboard: iOS keeps the presentation it had.
        var look = HostLook()
        look.loaded(at: 10)
        look.hostBecameActive(at: 10 + HostLook.freshWindow)
        XCTAssertFalse(look.margin)
    }

    func testAControllerShownAgainLaterGetsANewWindow() {
        // A controller iOS shows again after `freshWindow` (not seen on the simulator: every presentation there made a
        // new controller) counts as attached by the host's return as a new one would.
        var look = HostLook()
        look.loaded(at: 0)
        look.appeared(document: UUID(), at: 0.1)
        look.disappeared(document: UUID())
        look.appeared(document: UUID(), at: 30)
        look.hostBecameActive(at: 30.3)
        XCTAssertTrue(look.margin)
    }

    func testAReturnJustBeforeLoadingMeansTheMargin() {
        // Run 59: the notice came 32 ms before the new controller loaded and reached only the old one.
        var look = HostLook()
        look.loaded(at: 0)
        look.hostBecameActive(at: 9.968)
        look.disappeared(document: UUID())
        look.loaded(at: 10)
        XCTAssertTrue(look.margin)
    }

    func testAReturnLongBeforeLoadingDoesNotCount() {
        var look = HostLook()
        look.loaded(at: 0)
        look.hostBecameActive(at: 5)  // the old controller is 5 s old: kept
        look.disappeared(document: UUID())
        look.loaded(at: 5 + HostLook.earlyWindow)
        XCTAssertFalse(look.margin)
    }

    // MARK: Hide and show keep the look (rule 3)

    func testHideAndShowKeepTheMargin() {
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostBecameActive(at: 0.3)
        for i in 1...5 {
            look.disappeared(document: UUID())
            present(&look, at: Double(i) * 10, document: UUID())
            XCTAssertTrue(look.margin, "show \(i)")
        }
    }

    func testHideAndShowKeepNoMargin() {
        var look = HostLook()
        for i in 0...5 {
            if i > 0 { look.disappeared(document: UUID()) }
            present(&look, at: Double(i) * 10, document: UUID())
            XCTAssertFalse(look.margin, "show \(i)")
        }
    }

    // MARK: Back from another keyboard (rule 4)

    /// The margin after an app switch, in a field whose document is `doc`.
    private func afterAppSwitch(_ doc: UUID) -> HostLook {
        var look = HostLook()
        present(&look, at: 0, document: doc)
        look.hostBecameActive(at: 0.3)
        XCTAssertTrue(look.margin)
        return look
    }

    func testBackFromAnotherKeyboardShowsNoMargin() {
        // The field kept its document while Emoji was up; iOS draws no margin when Protly comes back (runs 159-169).
        let doc = UUID()
        var look = afterAppSwitch(doc)
        look.disappeared(document: doc)
        present(&look, at: 20, document: doc)
        XCTAssertFalse(look.margin)
    }

    func testAnotherDocumentIsHideAndShow() {
        var look = afterAppSwitch(UUID())
        look.disappeared(document: UUID())
        present(&look, at: 20, document: UUID())
        XCTAssertTrue(look.margin)
    }

    func testAnUnknownDocumentChangesNothing() {
        let doc = UUID()
        var look = afterAppSwitch(doc)
        look.disappeared(document: doc)
        look.loaded(at: 20)
        look.appeared(document: nil, at: 20.1)
        XCTAssertTrue(look.margin)
        var other = afterAppSwitch(doc)
        other.disappeared(document: nil)
        present(&other, at: 20, document: doc)
        XCTAssertTrue(other.margin)
    }

    func testAnAppSwitchInTheSameDocumentKeepsTheMargin() {
        // The field keeps its document across the background: the old controller goes, the new one appears in the
        // same document, and the host's notice comes after it (0.22-0.41 s) or just before it loaded (run 59).
        let doc = UUID()
        var late = HostLook()
        present(&late, at: 0, document: doc)
        late.disappeared(document: doc)
        present(&late, at: 10, document: doc)
        late.hostBecameActive(at: 10.3)
        XCTAssertTrue(late.margin)

        var early = afterAppSwitch(doc)
        early.hostBecameActive(at: 19.97)  // over the old controller, 19.97 s old: kept
        early.disappeared(document: doc)
        present(&early, at: 20, document: doc)
        XCTAssertTrue(early.margin)
    }

    // MARK: A new host (rule 1)

    func testANewHostShowsNoMargin() {
        // The host was terminated with the keyboard up: its controller never got viewDidDisappear.
        var look = HostLook()
        present(&look, at: 0, document: UUID())
        look.hostBecameActive(at: 0.3)
        present(&look, at: 20, document: UUID())
        XCTAssertFalse(look.margin)
    }
}
