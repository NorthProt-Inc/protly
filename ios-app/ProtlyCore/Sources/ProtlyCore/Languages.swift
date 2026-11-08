// The Chrome extension's target languages (src/lib/lang.js LANG_NAMES, same codes, names and order) and its
// draft prefix ("ru: 안녕" translates that draft into Russian). tests/ios-app.test.js fails when the list
// differs from LANG_NAMES; LanguagesTests repeats the cases of tests/lang.test.js for the prefix.

public enum Languages {
    /// ISO 639-1 codes (yue is 639-3), the extension's picker order.
    public static let names: [(code: String, name: String)] = [
        ("ko", "Korean"), ("en", "English"), ("ru", "Russian"), ("es", "Spanish"), ("ja", "Japanese"),
        ("zh", "Chinese"), ("fr", "French"), ("de", "German"), ("uk", "Ukrainian"), ("pt", "Portuguese"),
        ("ar", "Arabic"), ("be", "Belarusian"), ("bn", "Bengali"), ("bg", "Bulgarian"), ("yue", "Cantonese"),
        ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("et", "Estonian"),
        ("fi", "Finnish"), ("ka", "Georgian"), ("el", "Greek"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("id", "Indonesian"), ("it", "Italian"), ("kk", "Kazakh"), ("lv", "Latvian"),
        ("lt", "Lithuanian"), ("ms", "Malay"), ("mn", "Mongolian"), ("no", "Norwegian"), ("fa", "Persian"),
        ("pl", "Polish"), ("pa", "Punjabi"), ("ro", "Romanian"), ("sr", "Serbian"), ("sk", "Slovak"),
        ("sv", "Swedish"), ("tl", "Tagalog"), ("th", "Thai"), ("tr", "Turkish"), ("ur", "Urdu"),
        ("uz", "Uzbek"), ("vi", "Vietnamese"),
    ]

    public static func name(of code: String) -> String? {
        names.first { $0.code == code }?.name
    }

    /// The prefix of a draft: spaces, 2-3 ASCII letters that are a listed code, a colon, spaces. The code comes back
    /// lowercased and the text without the prefix; anything else is (nil, the whole text). The rule of the
    /// extension's parseLangPrefix (`^\s*([a-z]{2,3}):\s*`, case-insensitive), with one difference: "ko" counts
    /// here, because on the keyboard it asks for a Korean polish.
    public static func prefix(of text: String) -> (code: String?, text: String) {
        let s = text.unicodeScalars
        var i = s.startIndex
        while i < s.endIndex, isSpace(s[i]) { i = s.index(after: i) }
        let start = i
        var letters = 0
        while i < s.endIndex, letters < 4, isLetter(s[i]) { i = s.index(after: i); letters += 1 }
        guard (2...3).contains(letters), i < s.endIndex, s[i] == ":" else { return (nil, text) }
        let code = String(s[start..<i]).lowercased()
        guard name(of: code) != nil else { return (nil, text) }
        i = s.index(after: i)
        while i < s.endIndex, isSpace(s[i]) { i = s.index(after: i) }
        return (code, String(s[i...]))
    }

    /// The extension's parseLangPrefix: a leading prefix of a listed code but "ko" picks the whole draft's language
    /// and is dropped, and every mid-draft span after it is tagged for the model (tagSpans). MODE out sends this text.
    public static func parse(_ text: String) -> (lang: String?, text: String) {
        let p = prefix(of: text)
        guard let code = p.code, code != "ko" else { return (nil, tagSpans(text)) }
        return (code, tagSpans(p.text))
    }

    /// Mid-draft spans (docs/plans/2026-11-08-prefix-spans.md, lang.js tagSpans): "안녕 fr:고마워; 잘가" ->
    /// "안녕 <fr>고마워</fr> 잘가". A span opens at a lowercase listed code other than "ko", not right after an ASCII
    /// letter or digit, then `:`, optional spaces and Hangul at once, so "ID: abc", "No: 3", "http:" and "10:30"
    /// never open one. A single `;` closes it and is dropped; a run of two or more (;; is a sweat emoticon) is text.
    /// With no closing `;` the span runs to the end. Spans do not nest: an opener inside a span is text.
    public static func tagSpans(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while let open = spanOpener(s, from: i) {
            var to = s.count
            var next = s.count
            for j in open.from..<s.count where s[j] == ";" && s[j - 1] != ";" && (j + 1 == s.count || s[j + 1] != ";") {
                to = j
                next = j + 1
                break
            }
            out.append(contentsOf: s[i..<open.start])
            out.append(contentsOf: "<\(open.code)>".unicodeScalars)
            out.append(contentsOf: s[open.from..<to])
            out.append(contentsOf: "</\(open.code)>".unicodeScalars)
            i = next
        }
        out.append(contentsOf: s[i...])
        return String(out)
    }

    /// The first span opener at or after `from`: where its code starts, the code, and where the span's text starts.
    /// The regex of lang.js, `(?<![A-Za-z0-9])([a-z]{2,3}):\s*(?=[ᄀ-ᇿ㄰-㆏가-힯])`, then the code checked.
    private static func spanOpener(_ s: [Unicode.Scalar], from: Int) -> (start: Int, code: String, from: Int)? {
        var k = from
        while k < s.count {
            defer { k += 1 }
            guard k == 0 || !isASCIIAlphanumeric(s[k - 1]) else { continue }
            var e = k
            while e < s.count, e - k < 4, ("a"..."z").contains(s[e]) { e += 1 }
            guard (2...3).contains(e - k), e < s.count, s[e] == ":" else { continue }
            var t = e + 1
            while t < s.count, isSpace(s[t]) { t += 1 }
            guard t < s.count, isSpanHangul(s[t]) else { continue }
            let code = String(String.UnicodeScalarView(s[k..<e]))
            guard code != "ko", name(of: code) != nil else { continue }
            return (k, code, t)
        }
        return nil
    }

    private static func isASCIIAlphanumeric(_ c: Unicode.Scalar) -> Bool {
        isLetter(c) || ("0"..."9").contains(c)
    }

    /// lang.js's Hangul class: conjoining jamo, compatibility jamo, syllables.
    private static func isSpanHangul(_ c: Unicode.Scalar) -> Bool {
        (0x1100...0x11FF).contains(c.value) || (0x3130...0x318F).contains(c.value) || (0xAC00...0xD7AF).contains(c.value)
    }

    private static func isLetter(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    /// JavaScript's \s: its white space and line terminators. Not Foundation's set, which adds U+0085 and
    /// leaves out U+FEFF.
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
}
