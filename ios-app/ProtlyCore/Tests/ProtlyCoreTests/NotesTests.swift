import XCTest
@testable import ProtlyCore

// Plan 2026-11-08 Part A rules 1-3: `[...]` in the writer's own draft is a note for the model, never draft text.
// The shared cases (tests/fixtures/notes-cases.json) are the extension's splitNotes cases too.
final class NotesTests: XCTestCase {
    private func split(_ s: String) -> [String] {
        let r = Notes.split(s)
        return [r.text] + r.notes
    }

    func testTheSharedCases() throws {
        let cases = try SharedFixtures.cases("notes-cases.json")
        for c in cases {
            let draft = try XCTUnwrap(c["draft"] as? String)
            let r = Notes.split(draft)
            let why = "\(c["why"] ?? ""): \(draft.debugDescription)"
            XCTAssertEqual(r.text, c["text"] as? String, why)
            XCTAssertEqual(r.notes, c["notes"] as? [String], why)
        }
    }

    func testANoteNeedsALetter() {
        XCTAssertEqual(split("a [1] b"), ["a [1] b"])
        XCTAssertEqual(split("a [—] b"), ["a [—] b"])
        XCTAssertEqual(split("a [ㅋ] b"), ["a b", "ㅋ"])  // compatibility jamo are letters
        XCTAssertEqual(split("a [é] b"), ["a b", "é"])
    }

    func testSpacesAroundANoteBecomeOneOrNone() {
        XCTAssertEqual(split("a\t[x]\tb"), ["a b", "x"])
        XCTAssertEqual(split("a [x], b"), ["a, b", "x"])
        XCTAssertEqual(split("a [x]!"), ["a!", "x"])
        XCTAssertEqual(split("a [x]\nb"), ["a\nb", "x"])
        XCTAssertEqual(split("a\n  [x]  b"), ["a\nb", "x"])
    }

    func testNotesKeepTheirOrderAndTextKeepsItsLines() {
        XCTAssertEqual(split("[one] a\n\nb [two] c [three]"), ["a\n\nb c", "one", "two", "three"])
    }

    func testAPlainDraftIsUnchanged() {
        for s in ["", "  hi  ", "a ] [ b", "x[]y", "안녕 fr:고마워;"] {
            XCTAssertEqual(Notes.split(s).text, s, s)
            XCTAssertEqual(Notes.split(s).notes, [], s)
        }
    }
}
