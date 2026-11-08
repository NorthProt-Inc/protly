import XCTest
@testable import ProtlyCore

// The cases of tests/lang.test.js (parseLangPrefix), plus the one keyboard difference: "ko:" is a prefix here.
// Mid-draft spans (`fr:...;`, docs/plans/2026-11-08-prefix-spans.md) read the shared tests/fixtures/span-cases.json.
final class LanguagesTests: XCTestCase {
    private func parse(_ s: String) -> [String?] {
        let p = Languages.prefix(of: s)
        return [p.code, p.text]
    }

    func testTheListIsTheExtensionsList() {
        XCTAssertEqual(Languages.names.count, 47)  // tests/ios-app.test.js compares every entry with LANG_NAMES
        XCTAssertEqual(Languages.name(of: "ru"), "Russian")
        XCTAssertEqual(Languages.name(of: "yue"), "Cantonese")
        XCTAssertNil(Languages.name(of: "xx"))
    }

    func testAKnownCodePicksTheLanguageAndIsDropped() {
        XCTAssertEqual(parse("ru: 안녕"), ["ru", "안녕"])
        XCTAssertEqual(parse("ja: 첫줄\n둘째 줄"), ["ja", "첫줄\n둘째 줄"])
        XCTAssertEqual(parse("  RU:안녕"), ["ru", "안녕"])
        XCTAssertEqual(parse("ru:\n\n안녕"), ["ru", "안녕"])
        XCTAssertEqual(parse("\u{FEFF}\u{3000}es: 안녕"), ["es", "안녕"])  // JavaScript's \s has both
    }

    func testUnknownCodesALatePrefixAndURLsStayText() {
        for s in ["ok: 안녕", "안녕 ru:", "https://x.com 안녕", "xx: 안녕", "rus: 안녕", "r: 안녕", "ru 안녕", "겨: 안녕",
                  "\u{85}ru: 안녕", ""] {
            XCTAssertEqual(parse(s), [nil, s], s)
        }
    }

    func testKoIsAPrefixOnTheKeyboardOnly() {
        // parseLangPrefix refuses ko. On the keyboard "ko:" asks for a Korean polish (ActionAPI.mode).
        XCTAssertEqual(parse("ko: 안녕"), ["ko", "안녕"])
    }

    func testTheSharedSpanCases() throws {
        for c in try SharedFixtures.cases("span-cases.json") {
            let draft = try XCTUnwrap(c["draft"] as? String)
            let p = Languages.parse(draft)
            XCTAssertEqual(p.lang, c["lang"] as? String, draft)
            XCTAssertEqual(p.text, c["text"] as? String, draft)
        }
    }

    func testASpanRunsFromItsCodeToASingleSemicolon() {
        XCTAssertEqual(Languages.tagSpans("안녕 fr:고마워; 잘가"), "안녕 <fr>고마워</fr> 잘가")
        XCTAssertEqual(Languages.tagSpans("안녕 fr:고마워"), "안녕 <fr>고마워</fr>")  // no `;`: to the end
        XCTAssertEqual(Languages.tagSpans("a, yue:\n고마워;b"), "a, <yue>고마워</yue>b")  // \s spans lines
        XCTAssertEqual(Languages.tagSpans("안녕 fr:고마워;; 응"), "안녕 <fr>고마워;; 응</fr>")
        XCTAssertEqual(Languages.tagSpans("(fr:고마워)"), "(<fr>고마워)</fr>")
        XCTAssertEqual(Languages.tagSpans("안녕 fr:ㅋㅋ;"), "안녕 <fr>ㅋㅋ</fr>")  // compatibility jamo are Hangul
    }

    func testOnlyALowercaseListedCodeAfterANonAlphanumericOpensASpan() {
        for s in ["안녕 FR:고마워;", "안녕 xfr:고마워;", "안녕 1fr:고마워;", "안녕 ko:고마워;", "안녕 xx:고마워;",
                  "안녕 fr: hi;", "안녕 fr:;", "안녕 f:고마워;", "안녕 fran:고마워;", "안녕 fr;고마워", ""] {
            XCTAssertEqual(Languages.tagSpans(s), s, s)
        }
        XCTAssertEqual(Languages.tagSpans("_fr:고마워"), "_<fr>고마워</fr>")
    }

    func testParseKeepsTheLeadingPrefixAndTagsTheRest() {
        XCTAssertEqual(Languages.parse("RU: 안녕 fr:고마워;").lang, "ru")
        XCTAssertEqual(Languages.parse("RU: 안녕 fr:고마워;").text, "안녕 <fr>고마워</fr>")
        // ko: is no target: the whole draft, spans tagged (the keyboard reads "ko:" as a polish before this).
        XCTAssertNil(Languages.parse("ko: 안녕 fr:고마워;").lang)
        XCTAssertEqual(Languages.parse("ko: 안녕 fr:고마워;").text, "ko: 안녕 <fr>고마워</fr>")
    }
}
