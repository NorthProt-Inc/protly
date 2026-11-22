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
        // More text in front of the read text: the field is not what was read.
        XCTAssertFalse(FieldGuard.canReplace(draft, before: "Earlier. " + draft, after: ""))
    }

    /// K1b: the before-context is a window of the last sentences (about 300 units at most), so a read longer than
    /// that is checked on its end. A cut near the start looks the same as the window: the controller's "touched"
    /// flag (a key or a cursor move since the read) covers that case, not this rule.
    func testAWindowOfTheReadAgrees() {
        let long = String(repeating: "문장이 하나 있어요. ", count: 100)
        XCTAssertTrue(FieldGuard.canReplace(long, before: String(long.suffix(60)), after: ""))
        XCTAssertTrue(FieldGuard.canReplace(draft, before: String(draft.dropFirst(6)), after: ""))
        XCTAssertFalse(FieldGuard.canReplace(long, before: String(long.suffix(60)) + "x", after: ""))
        XCTAssertFalse(FieldGuard.canReplace(long, before: "", after: ""))
        // A window that starts inside a character (a combining mark after its base) agrees on its UTF-16 units.
        XCTAssertTrue(FieldGuard.canReplace("Cafe\u{301} au lait", before: "\u{301} au lait", after: ""))
        // The check after Replace uses the same rule on the result.
        XCTAssertTrue(FieldGuard.holdsResult("read 335/9/h6d75860b t4210", before: "read 335/9/h6d75860b t4210", after: ""))
        XCTAssertFalse(FieldGuard.holdsResult("read 335/9/h6d75860b t4210", before: "x read 335/9/h6d75860b t4210", after: ""))
        XCTAssertFalse(FieldGuard.holdsResult("abc", before: "abc", after: "left over"))
        // Undo of a long Replace (proven whole when it ended): the window shows the result's end.
        XCTAssertTrue(FieldGuard.canUndoReplace(long, before: String(long.suffix(50)), after: "", selected: ""))
        XCTAssertFalse(FieldGuard.canUndoReplace(long, before: "", after: "", selected: ""))
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

    /// Tower review of f0533ae: Read's Insert into a field that took only part of it (a length limit) leaves text
    /// that is a window of the insert's end; Undo then sent 8 deletes over 2 characters, into the user's own text.
    /// Insert's Undo needs all of the inserted text before the cursor, as on main; only a Replace the keyboard
    /// proved whole may be undone from a window of its end.
    func testInsertUndoNeedsAllOfTheInsert() {
        XCTAssertFalse(FieldGuard.canUndo("Looks OK", before: "OK", selected: ""))
        XCTAssertFalse(FieldGuard.canUndo("Looks OK", before: "Mine. OK", selected: ""))
        XCTAssertTrue(FieldGuard.canUndo("Looks OK", before: "Mine. Looks OK", selected: ""))
        XCTAssertTrue(FieldGuard.canUndoReplace("Looks OK", before: "OK", after: "", selected: ""))
    }

    /// Replace left "Hi|", then the user added " there" and selected it: Undo's first delete would take the selection,
    /// the next ones the user's text before it. With text selected Undo is refused, and the bar does not offer it.
    /// K1b: Undo of a whole-field Replace puts the read text back with the cursor at the end; text after the cursor
    /// (moved since) means the deletes would take the wrong characters.
    func testUndoOfAReplaceNeedsTheCursorAtTheEnd() {
        XCTAssertTrue(FieldGuard.canUndoReplace("Hello there.", before: "Hello there.", after: "", selected: ""))
        XCTAssertTrue(FieldGuard.canUndoReplace("Hello there.", before: "there.", after: "", selected: ""),
                      "a window of the result's end")
        XCTAssertFalse(FieldGuard.canUndoReplace("Hello there.", before: "Hello there.", after: " more", selected: ""))
        XCTAssertFalse(FieldGuard.canUndoReplace("Hello there.", before: "Hello", after: " there.", selected: ""))
        XCTAssertFalse(FieldGuard.canUndoReplace("Hello there.", before: "Hello there.", after: "", selected: "there"))
        XCTAssertFalse(FieldGuard.canUndoReplace("Hello there.", before: "Hello there.x", after: "", selected: ""))
        XCTAssertFalse(FieldGuard.canUndoReplace("", before: "", after: "", selected: ""))
    }

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
            XCTAssertEqual(FieldGuard.copyOnly(action, original: draft, isSelection: false, field: field("Earlier. " + draft)),
                           .fieldChanged, "K1b: the read was the whole field")
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

    /// The card's line says why in a few words, in the card's own style. The selection line fits Replace and Read's
    /// Insert alike.
    func testCopyOnlyLines() {
        XCTAssertEqual(FieldGuard.CopyOnly.fieldChanged.message, "The text changed while this ran. Copy the result instead.")
        XCTAssertEqual(FieldGuard.CopyOnly.selection.message, "Protly does not type over selected text. Copy the result instead.")
    }
}

/// Tower review of f0533ae, bugs 2 and 4: the two decisions FieldText makes on the proxy, as pure rules.
final class FieldDecisionTests: XCTestCase {
    /// Bug 4: the user tapped another field between Replace's deletes and its insert (up to WholeRead.moveWait): the
    /// insert would land there. Only a known, different document says so; with none from iOS the insert goes ahead (as
    /// before K1b: nothing better is known).
    func testTheInsertWaitsForTheSameField() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(FieldGuard.focus(before: a, now: a), .same)
        XCTAssertEqual(FieldGuard.focus(before: a, now: b), .other)
        XCTAssertEqual(FieldGuard.focus(before: nil, now: b), .unknown)
        XCTAssertEqual(FieldGuard.focus(before: a, now: nil), .unknown)
        XCTAssertEqual(FieldGuard.focus(before: a, now: b).logValue, 1)
        XCTAssertEqual(FieldGuard.focus(before: a, now: a).logValue, 0)
        XCTAssertEqual(FieldGuard.focus(before: nil, now: nil).logValue, -1)
    }

    /// Bug 2: a selection at the field's start that reaches a line feed shows both contexts empty, as select all
    /// does. After the +1 collapse, select all leaves nothing before the end: any text the walk to the end crossed, or
    /// any move it made, means the selection was partial (K1a: its own text, copy-only).
    func testACollapsedSelectionWithTextAfterItWasPartial() {
        XCTAssertFalse(WholeRead.wasPartialSelection(crossed: [], moved: 0))
        XCTAssertTrue(WholeRead.wasPartialSelection(crossed: Array("\nprivate notes".utf16), moved: -14))
        // A resync step moves without naming a unit: still not select all.
        XCTAssertTrue(WholeRead.wasPartialSelection(crossed: [], moved: -1))
    }
}
