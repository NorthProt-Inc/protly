import Foundation
import XCTest
@testable import ProtlyCore

// Insert deletes `original.count` characters and Undo `inserted.count`: both run only while the field
// still ends with exactly that text, so an edit anywhere in it while the request ran stops them.
final class FieldGuardTests: XCTestCase {
    let draft = "First line of a long draft that the user wrote. " + String(repeating: "Then more text. ", count: 10)

    func testInsertWhenTheFieldIsAsRead() {
        XCTAssertTrue(FieldGuard.canReplace(draft, before: draft, after: ""))
        XCTAssertTrue(FieldGuard.canReplace("안녕 👨‍👩‍👧", before: "안녕 👨‍👩‍👧", after: ""))
    }

    func testNoInsertAfterAnEditFarFromTheEnd() {
        // The user pasted near the start, then put the cursor back at the end: the last 40 characters match.
        let edited = "Fi" + "XYZ" + draft.dropFirst(2)
        XCTAssertEqual(String(edited.suffix(40)), String(draft.suffix(40)))
        XCTAssertFalse(FieldGuard.canReplace(draft, before: edited, after: ""))
        // A cut near the start: the field is shorter than what Insert would delete.
        XCTAssertFalse(FieldGuard.canReplace(draft, before: String(draft.dropFirst(6)), after: ""))
    }

    func testNoInsertWithTextAfterTheCursorOrNothingRead() {
        XCTAssertFalse(FieldGuard.canReplace(draft, before: draft, after: " tail"))
        XCTAssertFalse(FieldGuard.canReplace("", before: draft, after: ""))
    }

    func testUndoOnlyWhileTheInsertIsIntact() {
        let inserted = "Polished text that protly inserted, long enough to pass forty characters."
        XCTAssertTrue(FieldGuard.canUndo(inserted, before: "Earlier text. " + inserted, selected: ""))
        let cut = inserted.replacingOccurrences(of: "Polished ", with: "")
        XCTAssertEqual(String(cut.suffix(40)), String(inserted.suffix(40)))
        XCTAssertFalse(FieldGuard.canUndo(inserted, before: "Earlier text. " + cut, selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("", before: "x", selected: ""))
    }

    /// Replace left "Hi|", then the user added " there" and selected it: Undo's first delete would take the selection,
    /// the next ones the user's text before it. With text selected Undo is refused, and the bar does not offer it.
    func testNoUndoOverASelection() {
        XCTAssertTrue(FieldGuard.canUndo("Hi", before: "Hi", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("Hi", before: "Hi", selected: " there"))
        XCTAssertFalse(FieldGuard.canUndo("Hi", before: "Hi", selected: " "))
        XCTAssertTrue(FieldGuard.offersUndo(true, selected: ""))
        XCTAssertFalse(FieldGuard.offersUndo(true, selected: " there"))
        XCTAssertFalse(FieldGuard.offersUndo(false, selected: ""))
    }

    func testCharacterBoundariesDecide() {
        // An insert that joined the character before it is not intact: its delete count would take that
        // character too. Swift's hasSuffix compares whole characters; a UTF-16 or scalar compare would not.
        XCTAssertFalse(FieldGuard.canUndo("\u{301}abc", before: "xe\u{301}abc", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("\u{11A8}bc", before: "가\u{11A8}bc", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("🇷ab", before: "🇰🇷ab", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("\u{200D}👦", before: "👨\u{200D}👦", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("\n", before: "a\r\n", selected: ""))  // "\r\n" is one character
        XCTAssertFalse(FieldGuard.canUndo("a\r", before: "a\r\n", selected: ""))
        // Canonically equal text is the same text, with the same character count.
        let nfc = "안녕", nfd = "안녕".decomposedStringWithCanonicalMapping
        XCTAssertTrue(FieldGuard.canReplace(nfc, before: nfd, after: ""))
        XCTAssertEqual(nfc.count, nfd.count)
        XCTAssertTrue(FieldGuard.canUndo("\u{00C5}", before: "x\u{212B}", selected: ""))
    }

    // MARK: Copy-only cards (P10, P1a cause 3)

    private func field(_ before: String, after: String = "", selected: String = "") -> FieldWatch.Observed {
        FieldWatch.Observed(before: before, after: after, selected: selected)
    }

    /// P1a cause 3: after a select all of a long draft, `selectedText` held only its first 43 units, and the old guard
    /// compared it with that same text. A card read from a selection never writes, however the field looks.
    func testASelectionCardIsCopyOnlyFromTheStart() {
        let cut = "First line of a long draft. Second line."  // what selectedText returned
        for action in [ActionMode.out, .fix] {
            XCTAssertEqual(FieldGuard.copyOnly(action, original: cut, isSelection: true, field: nil), .selection,
                           "\(action): the card opens copy-only")
            XCTAssertEqual(FieldGuard.copyOnly(action, original: cut, isSelection: true, field: field("", selected: cut)),
                           .selection, "\(action): the selection still reads as read")
            XCTAssertEqual(FieldGuard.copyOnly(action, original: cut, isSelection: true, field: field(cut)), .selection,
                           "\(action): the selection is gone")
        }
    }

    /// Read inserts at the cursor; over a selection it would type over text it never saw, and Undo would put back
    /// only what `selectedText` showed.
    func testReadNeverInsertsOverASelection() {
        XCTAssertEqual(FieldGuard.copyOnly(.in, original: "", isSelection: false, field: field("Hi ", selected: "there")),
                       .selection)
        XCTAssertEqual(FieldGuard.copyOnly(.in, original: "", isSelection: false, field: field("", selected: draft)),
                       .selection)
        // No selection: the reply goes in at the cursor, wherever it is, as before.
        XCTAssertNil(FieldGuard.copyOnly(.in, original: "", isSelection: false, field: nil))
        XCTAssertNil(FieldGuard.copyOnly(.in, original: "", isSelection: false, field: field("")))
        XCTAssertNil(FieldGuard.copyOnly(.in, original: "", isSelection: false, field: field("Hi ", after: " tail")))
    }

    /// A read without a selection keeps its rule: the card opens with Replace to come, and once done it writes only
    /// while the field holds what was read (canReplace).
    func testAWholeFieldReadWritesWhileTheFieldHoldsIt() {
        for action in [ActionMode.out, .fix] {
            XCTAssertNil(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: nil))
            XCTAssertNil(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field(draft)))
            XCTAssertNil(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field("Earlier. " + draft)))
            XCTAssertEqual(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field(draft + "x")),
                           .fieldChanged)
            XCTAssertEqual(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field(draft, after: " tail")),
                           .fieldChanged)
            XCTAssertEqual(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field("")), .fieldChanged)
        }
    }

    /// Text selected after a whole-field read: the field before the selection still ends with the read text, but a
    /// delete would take the selection first and then the end of the draft.
    func testNoReplaceOverASelectionMadeAfterTheRead() {
        XCTAssertTrue(FieldGuard.canReplace("hello", before: "hello", after: ""))
        XCTAssertEqual(FieldGuard.copyOnly(.out, original: "hello", isSelection: false,
                                           field: field("hello", selected: " world")), .selection)
        // A field that changed says so, selection or not.
        XCTAssertEqual(FieldGuard.copyOnly(.out, original: "hello", isSelection: false,
                                           field: field("help", selected: "x")), .fieldChanged)
    }

    /// The card's line says why in a few words, in the card's own style.
    func testCopyOnlyLines() {
        XCTAssertEqual(FieldGuard.CopyOnly.fieldChanged.message, "The text changed while this ran. Copy the result instead.")
        XCTAssertEqual(FieldGuard.CopyOnly.selection.message, "Selected text cannot be replaced. Copy the result instead.")
    }

    /// keyboard-ui 003 (P6): Cancel moves the cursor back only while the text the read moved over is still just
    /// before it.
    func testRestoreOnlyWhileTheReadTextIsBeforeTheCursor() {
        XCTAssertTrue(FieldGuard.canRestore("hello there", before: "hello there"))
        XCTAssertTrue(FieldGuard.canRestore("hello", before: "x hello"))
        XCTAssertFalse(FieldGuard.canRestore("hello", before: "hello!"))
        XCTAssertFalse(FieldGuard.canRestore("", before: "x"))
    }
}
