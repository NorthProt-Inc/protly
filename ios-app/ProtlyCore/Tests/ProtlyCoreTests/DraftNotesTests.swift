import XCTest
@testable import ProtlyCore

// Plan 2026-11-08 Part A rules 4, 5 and 10 on the phone: the bar, the mode and the request decide from the draft's
// text without its notes, and the notes travel in a NOTES block before the DRAFT (MODE out and fix, never Read).
final class DraftNotesTests: XCTestCase {
    private func message(_ text: String) -> String {
        ActionAPI.userMessage(mode: ActionAPI.mode(forDraft: text), text: text)
    }

    func testTheModeIgnoresNotes() {
        XCTAssertEqual(ActionAPI.mode(forDraft: "see you [좀 더 정중하게]"), .fix)  // Hangul only in a note
        XCTAssertEqual(ActionAPI.mode(forDraft: "[formal] 내일 보자"), .out)
        XCTAssertEqual(ActionAPI.mode(forDraft: "[짧게] ko: 낼 봐"), .fix)
        XCTAssertTrue(ActionAPI.isKoreanPolish("[짧게] ko: 낼 봐"))  // the prefix is read after leading notes
        XCTAssertFalse(ActionAPI.isKoreanPolish("ko: see you [짧게]"))
    }

    func testNotesGoInABlockRightBeforeTheDraft() {
        XCTAssertEqual(message("내일 보자 [좀 더 정중하게] [짧게]"),
                       "MODE: out\nTARGET: English\n\nNOTES:\n- 좀 더 정중하게\n- 짧게\n\nDRAFT:\n내일 보자")
        XCTAssertEqual(message("[formal] ru: 안녕"), "MODE: out\nTARGET: Russian\n\nNOTES:\n- formal\n\nDRAFT:\n안녕")
        XCTAssertEqual(message("see you [warmer]"), "MODE: fix\n\nNOTES:\n- warmer\n\nDRAFT:\nsee you")
        XCTAssertEqual(message("[짧게] ko: 낼 봐"), "MODE: fix\n\nNOTES:\n- 짧게\n\nDRAFT:\n낼 봐")
        // No notes: no block, the draft exactly as before.
        XCTAssertEqual(message(" see you [1] "), "MODE: fix\n\nDRAFT:\n see you [1] ")
    }

    func testSpansAreTaggedInTheTextNeverInANote() {
        XCTAssertEqual(message("오늘 fr:고마워 [짧게]; 잘가 [fr:로 하지 마]"),
                       "MODE: out\nTARGET: English\n\nNOTES:\n- 짧게\n- fr:로 하지 마\n\nDRAFT:\n오늘 <fr>고마워</fr> 잘가")
    }

    func testTheDraftIsSplitOnce() {
        // What is left after one pass is draft text, even when it looks like a note now.
        XCTAssertEqual(message("a [note with [nested] text] b"),
                       "MODE: fix\n\nNOTES:\n- nested\n\nDRAFT:\na [note with text] b")
        // "[ 안녕]" is left: a second split would empty it.
        XCTAssertEqual(Notes.split("[[ㅋ] 안녕]").text, "[ 안녕]")
        XCTAssertEqual(BarAction.center(text: "[[ㅋ] 안녕]", canUndo: false, clipboardIsNew: false),
                       .translate(target: "English"))
        XCTAssertEqual(ActionAPI.mode(forDraft: "[[ㅋ] 안녕]"), .out)
        // "ko: [ 안녕]" is left: a Korean polish, which a second split would turn into a bare "ko:".
        XCTAssertEqual(message("ko: [[x] 안녕]"), "MODE: fix\n\nNOTES:\n- x\n\nDRAFT:\n[ 안녕]")
        XCTAssertEqual(BarAction.center(text: "ko: [[x] 안녕]", canUndo: false, clipboardIsNew: false), .polish(korean: true))
    }

    func testReadNeverSplits() {
        XCTAssertEqual(ActionAPI.userMessage(mode: .in, text: "hi [x]"), "MODE: in\n\nTEXT:\nhi [x]")
        XCTAssertNotNil(try? ActionAPI.request(mode: .in, text: "[x]", system: "S", apiKey: "k").get())
    }

    func testANotesOnlyDraftBuildsNoRequest() {
        for mode in [ActionMode.out, .fix] {
            for text in ["[x]", " [짧게]\n[y] "] {
                guard case .failure(let e) = ActionAPI.request(mode: mode, text: text, system: "S", apiKey: "k") else {
                    return XCTFail(text)
                }
                XCTAssertEqual(e.kind, .notesOnly, text)
            }
        }
        XCTAssertEqual(ActionError(.notesOnly).message, "Add the message too. [Brackets] are notes for protly.")
        XCTAssertNotNil(try? ActionAPI.request(mode: .fix, text: "hi [x]", system: "S", apiKey: "k").get())
        // Only notes make that error: a draft without any is sent as before.
        XCTAssertNotNil(try? ActionAPI.request(mode: .fix, text: "", system: "S", apiKey: "k").get())
    }

    func testTheBarReadsTheTextWithoutNotes() {
        func center(_ t: String, clipboardIsNew: Bool = false) -> BarAction? {
            BarAction.center(text: t, canUndo: false, clipboardIsNew: clipboardIsNew)
        }
        // Notes only: what an empty draft shows.
        XCTAssertNil(center("[짧게]"))
        XCTAssertEqual(center(" [짧게] [x] ", clipboardIsNew: true), .read)
        XCTAssertEqual(BarAction.protlyKey(text: "[x]", canUndo: false, clipboardIsNew: false), .read)
        XCTAssertEqual(center("[x]", clipboardIsNew: false), center("", clipboardIsNew: false))
        XCTAssertEqual(center("see you [좀 더 정중하게]"), .polish(korean: false))
        XCTAssertEqual(center("[formal] ru: 안녕"), .translate(target: "Русский"))
        XCTAssertEqual(center("[짧게] ko: 낼 봐"), .polish(korean: true))
        XCTAssertEqual(BarAction.call(.out, text: "[formal] ru: 안녕"), .translate(target: "Русский"))
        XCTAssertEqual(BarAction.center(text: "[x]", canUndo: true, clipboardIsNew: false), .undo)
    }
}
