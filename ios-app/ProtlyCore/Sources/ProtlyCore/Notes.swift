// Notes in the writer's own draft (plan 2026-11-08 Part A): `[좀 더 정중하게]` is an instruction to the model for this
// message, never draft text. The extension's splitNotes (src/lib/lang.js) follows the same rules; both read the
// cases in tests/fixtures/notes-cases.json. Only the writer's drafts are split (MODE out and fix), never Read.

public enum Notes {
    /// The draft without its notes, and the notes in order.
    /// 1. A note is `[` + content + `]`, the content without `[` or `]` and with a letter (\p{L}), trimmed. So `[1]`,
    ///    `[]` and `[ ]` stay text, and in `[a [b] c]` only `[b]` is a note (one pass).
    /// 2. An unmatched `[` or `]` stays text.
    /// 3. A note and the spaces around it become one space when the
    ///    line has text on both sides of it, else nothing. Closing punctuation right after it counts as no text, so
    ///    `Hello [x].` gives `Hello.`. The text is trimmed at both ends; line breaks stay.
    public static func split(_ draft: String) -> (text: String, notes: [String]) {
        let s = Array(draft.unicodeScalars)
        var found: [(open: Int, close: Int, note: String)] = []
        var open: Int?
        for (i, c) in s.enumerated() {
            if c == "[" {
                open = i
            } else if c == "]", let o = open {
                open = nil
                let note = trim(s[(o + 1)..<i])
                if note.contains(where: isLetter) { found.append((o, i, string(note))) }
            }
        }
        guard !found.isEmpty else { return (draft, []) }

        var out: [Unicode.Scalar] = []
        var notes: [String] = []
        var pos = 0
        for f in found {
            // A space this puts in front of a next note goes again with that note's own spaces: a run of notes
            // ends up as one space or none.
            out += s[pos..<f.open]
            notes.append(f.note)
            var end = f.close + 1
            while let last = out.last, isHorizontalSpace(last) { out.removeLast() }
            while end < s.count, isHorizontalSpace(s[end]) { end += 1 }
            let textBefore = out.last.map { !isLineBreak($0) } ?? false
            let textAfter = end < s.count && !isLineBreak(s[end]) && !closing.contains(s[end])
            if textBefore && textAfter { out.append(" ") }
            pos = end
        }
        out += s[pos...]
        return (string(trim(out[...])), notes)
    }

    /// Punctuation that ends what comes before it: no space goes in front of it.
    static let closing: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "。", "、", "！", "？", "，", "）", "」", "』",
    ]

    /// \p{L}: a letter of any script, Hangul jamo included; not a digit, mark or symbol.
    static func isLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// JavaScript's line terminators.
    static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}"
    }

    static func isHorizontalSpace(_ c: Unicode.Scalar) -> Bool {
        Languages.isSpace(c) && !isLineBreak(c)
    }

    /// JavaScript's trim(): its \s at both ends.
    private static func trim(_ s: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        var a = s.startIndex, b = s.endIndex
        while a < b, Languages.isSpace(s[a]) { a += 1 }
        while b > a, Languages.isSpace(s[b - 1]) { b -= 1 }
        return s[a..<b]
    }

    private static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        return String(v)
    }
}
