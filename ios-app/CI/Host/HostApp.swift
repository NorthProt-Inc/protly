import Combine
import SwiftUI
import UIKit
import WebKit

/// CI-only host for the keyboard screenshots (ios-app/CI/README.md). `-screen <name>` on the command line picks a
/// screen; every screen is offline:
/// - none: one multi-line field, focused on launch, on one solid color that measure.py knows (`HOST_BG`).
///   `-prefill "text"` puts text in it, and `-fills "a|b"` adds one button per draft (`fill-1`, `fill-2`) that puts
///   that draft in it with the keyboard up (keyboard-ui 003: the stub's marker drafts, CardChecks.swift).
/// - `uikit`: a UITextView (typing-fixes 004: the edit menu and the space trackpad) whose selection, marked text and
///   first and last word frames are published as accessibility values for XCUITest.
/// - `web`: a dark web composer (typing-fixes 004: Return in web fields, the word's ink on a dark page) in a WKWebView,
///   from the bundled web-composer.html. Its state is published as an accessibility value and every DOM event is
///   appended to Documents/web-events.txt, which run-shots.sh copies into the run folder.
/// Every screen has `Clear` (empties the field without keys) and `Dismiss` (the field loses focus, which hides the
/// keyboard) in the top-right corner, away from the field and the center column measure.py samples.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            switch UserDefaults.standard.string(forKey: "screen") ?? "" {
            case "web": WebComposerScreen()
            case "uikit": TextViewScreen()
            case "readweb": ReadWebScreen()
            default: HostView()
            }
        }
    }
}

/// measure.py HOST_BG = (32, 160, 96). It samples this at 30% of the screen height, so every screen keeps its content
/// above that line and the center column below it is only background.
let hostBackground = Color(red: 32 / 255, green: 160 / 255, blue: 96 / 255)

struct HostView: View {
    @State private var text = UserDefaults.standard.string(forKey: "prefill") ?? ""
    @FocusState private var focused: Bool
    private let fills = (UserDefaults.standard.string(forKey: "fills") ?? "").split(separator: "|").map(String.init)

    var body: some View {
        ZStack(alignment: .topLeading) {
            hostBackground.ignoresSafeArea()
            // The field stays in the top-left so the center column below it is only background.
            TextField("", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .accessibilityIdentifier("field")
                .foregroundStyle(.white)
                .frame(width: 200, alignment: .leading)
                .padding(.leading, 16)
                .padding(.top, 24)
            VStack(alignment: .trailing, spacing: 16) {
                Button("Clear") { text = "" }
                    .accessibilityIdentifier("clear")
                Button("Dismiss") { focused = false }
                    .accessibilityIdentifier("dismiss")
                // Above 30% of the height (measure.py's background sample), right of the field.
                HStack(spacing: 12) {
                    ForEach(Array(fills.enumerated()), id: \.offset) { i, draft in
                        Button("F\(i + 1)") { text = draft }
                            .accessibilityIdentifier("fill-\(i + 1)")
                    }
                }
                if ReadDrafts.enabled {
                    // Probe 3: the keyboard comes back after Dismiss without a tap in the field (the cursor stays).
                    Button("Focus") { focused = true }
                        .font(.caption)
                        .accessibilityIdentifier("rfocus")
                    ReadFillButtons { i in text = ReadDrafts.all[i].text }
                }
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 24)
        }
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // focus right at launch is sometimes dropped
            focused = true
        }
    }
}

/// A small caption whose accessibility value carries one reading for XCUITest (exact, unlike OCR).
struct Probe: View {
    let id: String
    let value: String

    var body: some View {
        Text("\(id) \(value)")
            .font(.system(size: 9))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: 90, alignment: .trailing)
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
    }
}

// MARK: - UIKit text view (`-screen uikit`)

/// A UITextView whose accessibility value is always its text: an empty one reads "" (Driver.clearField), not nil.
final class ProbeTextView: UITextView {
    override var accessibilityValue: String? {
        get { text ?? "" }
        set {}
    }
}

@MainActor
final class TextViewModel: ObservableObject {
    /// `location,length` of the selection, in UTF-16 units.
    @Published var selection = ""
    @Published var marked = ""
    /// `x,y,w,h` in screen points: where a double-tap selects that word.
    @Published var firstWord = ""
    @Published var lastWord = ""
    weak var textView: UITextView?

    func clear() {
        textView?.text = ""
        refresh()
    }

    func dismiss() {
        textView?.resignFirstResponder()
    }

    func focus() {
        textView?.becomeFirstResponder()
    }

    /// diag/p1-phone-read: a read draft in the text view, the cursor at its end or in its second paragraph.
    func fill(_ i: Int) {
        guard let tv = textView else { return }
        let draft = ReadDrafts.all[i]
        tv.inputDelegate?.textWillChange(tv)
        tv.text = draft.text
        tv.inputDelegate?.textDidChange(tv)
        tv.inputDelegate?.selectionWillChange(tv)
        tv.selectedRange = NSRange(location: draft.cursor, length: 0)
        tv.inputDelegate?.selectionDidChange(tv)
        refresh()
    }

    /// diag/p1-phone-read probe 3: the whole text selected, as Select All in the edit menu would (the cut-short
    /// panel's advice), so the read takes its selection path.
    func selectAll() {
        guard let tv = textView else { return }
        tv.inputDelegate?.selectionWillChange(tv)
        tv.selectedRange = NSRange(location: 0, length: (tv.text ?? "").utf16.count)
        tv.inputDelegate?.selectionDidChange(tv)
        refresh()
    }

    /// diag/p1-phone-read probe 3: the selection set again where it is, with the input delegate told, as the text
    /// system does when the host moves the caret: does the keyboard's context then come back as a window?
    func resync() {
        guard let tv = textView else { return }
        let r = tv.selectedRange
        tv.inputDelegate?.selectionWillChange(tv)
        tv.selectedRange = r
        tv.inputDelegate?.selectionDidChange(tv)
        refresh()
    }

    /// Polled (5 times a second): the keyboard moves the caret through the text input system, which does not always
    /// call the delegate.
    func refresh() {
        guard let tv = textView else { return }
        let r = tv.selectedRange
        update(\.selection, "\(r.location),\(r.length)")
        update(\.marked, tv.markedTextRange == nil ? "no" : "yes")
        let words = Self.wordRanges(tv.text ?? "")
        update(\.firstWord, words.first.flatMap { Self.frame(of: $0, in: tv) } ?? "")
        update(\.lastWord, words.last.flatMap { Self.frame(of: $0, in: tv) } ?? "")
    }

    private func update(_ key: ReferenceWritableKeyPath<TextViewModel, String>, _ value: String) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Runs of characters that are not a space, a tab or a line break, in UTF-16 units.
    static func wordRanges(_ s: String) -> [NSRange] {
        let ns = s as NSString
        var ranges: [NSRange] = []
        var start: Int?
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            let blank = c == 0x20 || c == 0x0A || c == 0x09 || c == 0xA0
            if blank, let s0 = start {
                ranges.append(NSRange(location: s0, length: i - s0))
                start = nil
            } else if !blank && start == nil {
                start = i
            }
        }
        if let s0 = start { ranges.append(NSRange(location: s0, length: ns.length - s0)) }
        return ranges
    }

    static func frame(of range: NSRange, in tv: UITextView) -> String? {
        guard let a = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let b = tv.position(from: a, offset: range.length),
              let textRange = tv.textRange(from: a, to: b) else { return nil }
        let rect = tv.firstRect(for: textRange)
        guard !rect.isNull, !rect.isInfinite, rect.width > 0 else { return nil }
        let r = tv.convert(rect, to: nil)
        return String(format: "%.1f,%.1f,%.1f,%.1f", r.minX, r.minY, r.width, r.height)
    }
}

struct TextViewField: UIViewRepresentable {
    let model: TextViewModel

    func makeUIView(context: Context) -> ProbeTextView {
        let tv = ProbeTextView()
        tv.backgroundColor = .clear
        tv.textColor = .white
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        // Apple's keyboard (menu-0) then types exactly the keys the test taps.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.accessibilityIdentifier = "field"
        model.textView = tv
        return tv
    }

    func updateUIView(_ uiView: ProbeTextView, context: Context) {}
}

struct TextViewScreen: View {
    @StateObject private var model = TextViewModel()
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            hostBackground.ignoresSafeArea()
            TextViewField(model: model)
                .frame(width: 200, height: 80)
                .padding(.leading, 16)
                .padding(.top, 24)
            VStack(alignment: .trailing, spacing: 10) {
                Button("Clear") { model.clear() }
                    .accessibilityIdentifier("clear")
                Button("Dismiss") { model.dismiss() }
                    .accessibilityIdentifier("dismiss")
                Probe(id: "sel", value: model.selection)
                Probe(id: "marked", value: model.marked)
                Probe(id: "first-word", value: model.firstWord)
                Probe(id: "last-word", value: model.lastWord)
                if ReadDrafts.enabled {
                    HStack(spacing: 10) {
                        Button("SelAll") { model.selectAll() }
                            .font(.caption)
                            .accessibilityIdentifier("rselall")
                        Button("Sync") { model.resync() }
                            .font(.caption)
                            .accessibilityIdentifier("rsync")
                        Button("Focus") { model.focus() }
                            .font(.caption)
                            .accessibilityIdentifier("rfocus")
                    }
                    ReadFillButtons { i in model.fill(i) }
                }
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 24)
        }
        .onReceive(tick) { _ in model.refresh() }
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // focus right at launch is sometimes dropped
            model.focus()
        }
    }
}

// MARK: - Web composer (`-screen web`)

@MainActor
final class WebModel: NSObject, ObservableObject, WKScriptMessageHandler {
    /// The page's JSON state: each field's text, the sent and submitted lists, the text when Return arrived, a trace.
    @Published var state = ""
    /// JSON {"composer": [x, y, w, h], ...} in screen points.
    @Published var rects = ""
    weak var webView: WKWebView?
    private let events = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("web-events.txt")

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            append("host: malformed message \(message.body)")
            return
        }
        switch kind {
        case "event":
            if let line = body["line"] as? String { append(line) }
        case "state":
            if let json = body["json"] as? String, json != state { state = json }
            if let r = body["rects"] as? [String: Any] { publish(r) }
        default:
            append("host: unknown message kind \(kind)")
        }
    }

    func clear() {
        webView?.evaluateJavaScript("clearAll()") { [weak self] _, error in
            if let error { self?.append("host: clearAll() failed: \(error)") }
        }
    }

    func dismiss() {
        webView?.evaluateJavaScript("document.activeElement && document.activeElement.blur()", completionHandler: nil)
        webView?.endEditing(true)
    }

    /// diag/p1-phone-read: a read draft in the read-probe page's focused field (read-probe.html fill()).
    func fill(_ i: Int) {
        let draft = ReadDrafts.all[i]
        guard let data = try? JSONEncoder().encode(draft.text), let json = String(data: data, encoding: .utf8) else {
            append("host: fill \(i) not encoded")
            return
        }
        webView?.evaluateJavaScript("fill(\(json), \(draft.cursor))") { [weak self] _, error in
            if let error { self?.append("host: fill() failed: \(error)") }
        }
    }

    func fail(_ why: String) {
        state = "{\"error\":\"\(why)\"}"
    }

    /// Page coordinates (CSS px from the viewport's top-left) to screen points: the page neither scrolls nor zooms.
    private func publish(_ r: [String: Any]) {
        guard let web = webView else { return }
        var out: [String: [Double]] = [:]
        for (name, v) in r {
            guard let a = (v as? [NSNumber])?.map({ $0.doubleValue }), a.count == 4 else { continue }
            let rect = web.convert(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), to: nil)
            out[name] = [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8), s != rects else { return }
        rects = s
    }

    private func append(_ line: String) {
        guard let url = events else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

struct WebComposer: UIViewRepresentable {
    let model: WebModel
    var page = "web-composer"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(model, name: "protly")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityIdentifier = "web"
        model.webView = web
        if let url = Bundle.main.url(forResource: page, withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let model = model
            let page = page
            Task { @MainActor in model.fail("\(page).html is not in the bundle") }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebComposerScreen: View {
    @StateObject private var model = WebModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            hostBackground.ignoresSafeArea()
            // Ends about 240 pt down, above measure.py's background sample at 30% of the height.
            WebComposer(model: model)
                .frame(width: 280, height: 184)
                .padding(.top, 8)
            VStack(alignment: .trailing, spacing: 10) {
                Button("Clear") { model.clear() }
                    .accessibilityIdentifier("clear")
                Button("Dismiss") { model.dismiss() }
                    .accessibilityIdentifier("dismiss")
                Probe(id: "web-state", value: model.state)
                Probe(id: "web-rects", value: model.rects)
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 24)
        }
    }
}

// MARK: - diag/p1-phone-read: whole-field read probe

/// The read probe's drafts (`-readfills 1`): synthetic Korean paragraphs, each starting with a token `\u{00A7}<n> ` so
/// the CI stub can say which paragraphs a read carried. `cursor` is a UTF-16 offset: the end, or the middle of the
/// second paragraph. ios-app/CI/UITests/ReadChecks.swift names the same drafts in the same order.
enum ReadDrafts {
    struct Draft {
        let name: String
        let text: String
        let cursor: Int
    }

    static var enabled: Bool { UserDefaults.standard.string(forKey: "readfills") == "1" }

    static let sentence = "\u{C624}\u{B298} \u{D68C}\u{C758} \u{B0B4}\u{C6A9} \u{C815}\u{B9AC}\u{D574}\u{C11C} \u{BCF4}\u{B0B4}\u{C904}\u{AC8C}."

    /// diag/p1-walk-back-unique (`-uniquedrafts 1`): every sentence starts with its own number (`3-12 `), so no two
    /// stretches of a draft read the same (run 7f2f443-135: jumps over 3 repeated sentences changed nothing).
    static var unique: Bool { UserDefaults.standard.string(forKey: "uniquedrafts") == "1" }

    /// diag/p1-walk-back-mix: with `-uniquedrafts 1` the numbered sentences take turns: the Korean one, an English one
    /// with an emoji (a surrogate pair, 2 UTF-16 units), a Korean one with an emoji.
    static let mixed = [sentence, "Send me the notes after the call \u{1F44D}.", "\u{D68C}\u{C758} \u{B05D}\u{B098}\u{ACE0} \u{C804}\u{D654}\u{D560}\u{AC8C} \u{1F642}."]

    static func paragraphs(_ count: Int, sentences: Int) -> [String] {
        (1...count).map { k in
            "\u{00A7}\(k) " + (1...sentences).map { j in unique ? "\(k)-\(j) " + mixed[(k + j) % 3] : sentence }.joined(separator: " ")
        }
    }

    static func make(_ name: String, _ paras: [String], _ separator: String, mid: Bool) -> Draft {
        let text = paras.joined(separator: separator)
        let start = (paras[0] + separator).utf16.count
        return Draft(name: name, text: text, cursor: mid ? start + paras[1].utf16.count / 2 : text.utf16.count)
    }

    static let all: [Draft] = [
        make("p3", paragraphs(3, sentences: 1), "\n\n", mid: false),
        make("p3mid", paragraphs(3, sentences: 1), "\n\n", mid: true),
        make("p5", paragraphs(5, sentences: 3), "\n\n", mid: false),
        make("p5mid", paragraphs(5, sentences: 3), "\n\n", mid: true),
        make("l5", paragraphs(5, sentences: 1), "\n", mid: false),
        make("long", paragraphs(5, sentences: 15), "\n\n", mid: false),
        make("longmid", paragraphs(5, sentences: 15), "\n\n", mid: true),
        // diag/p1-walk-back-mix: with `-uniquedrafts 1` xlong has 60 sentences a paragraph (about 12 000 units).
        make("xlong", paragraphs(8, sentences: unique ? 60 : 20), "\n\n", mid: false),
    ] + window

    // MARK: Probe 3 (test5i_readwindow): what bounds the before-window, select all, a step over a line break

    /// The sentence without its period: chat text often has none.
    static let clause = String(sentence.dropLast())
    /// One word of 14 syllables, as a sentence (15 units, 1 word).
    static let longWord = "\u{AC00}\u{B098}\u{B2E4}\u{B77C}\u{B9C8}\u{BC14}\u{C0AC}\u{C544}\u{C790}\u{CC28}\u{CE74}\u{D0C0}\u{D30C}\u{D558}."
    /// Twelve one-syllable words, as a sentence (24 units, 12 words).
    static let shortWords = "\u{AC00} \u{B098} \u{B2E4} \u{B77C} \u{B9C8} \u{BC14} \u{C0AC} \u{C544} \u{C790} \u{CC28} \u{CE74} \u{D0C0}."
    /// Ends every paragraph of the skip drafts: FieldText's probe steps over the line break only after a "¶".
    static let pilcrow = "\u{00B6}"

    static func atEnd(_ name: String, _ text: String) -> Draft {
        Draft(name: name, text: text, cursor: text.utf16.count)
    }

    static func skipParagraphs() -> [String] {
        paragraphs(3, sentences: 1).map { $0 + pilcrow }
    }

    /// rfill-9 ... rfill-18, in ReadChecks.swift ReadProbe.window order.
    static let window: [Draft] = [
        // One paragraph, no sentence punctuation (382 units).
        atEnd("run", "\u{00A7}1 " + Array(repeating: clause, count: 20).joined(separator: " ")),
        // Eight chat lines, single line feeds, no punctuation (175 units).
        atEnd("lines", (1...8).map { "\u{00A7}\($0) " + clause }.joined(separator: "\n")),
        // Twelve one-word sentences (191 units): a length bound and a word bound give different windows.
        atEnd("w1", Array(repeating: longWord, count: 12).joined(separator: " ")),
        // Six twelve-word sentences (149 units).
        atEnd("w12", Array(repeating: shortWords, count: 6).joined(separator: " ")),
        // l5 with the cursor in its second line: does the after-context stop before a single line feed too?
        make("l5mid", paragraphs(5, sentences: 1), "\n", mid: true),
        // p3 ending in a line feed, the cursor on the empty last line (71 units).
        atEnd("trail", paragraphs(3, sentences: 1).joined(separator: "\n\n") + "\n"),
        // The cursor in the middle of the first paragraph: the read stops at its end, then the probe steps on.
        Draft(name: "skip", text: skipParagraphs().joined(separator: "\n\n"), cursor: skipParagraphs()[0].utf16.count / 2),
        // The same with the cursor at the end of the field: a step there must change nothing.
        atEnd("skipend", skipParagraphs().joined(separator: "\n\n")),
        // Single line feeds, the cursor in the middle of the first line.
        Draft(name: "skipl", text: skipParagraphs().joined(separator: "\n"), cursor: skipParagraphs()[0].utf16.count / 2),
        // ReadChecks.swift ReadProbe.typed (run 3c208a9-124 typed it and the read carried all of it), as a fill.
        atEnd("en", "we met today. it went well.\n\nsee you soon. call me later.\n\nthanks again. bye now."),
    ]
}

/// Buttons `rfill-1` ... `rfill-18`, rows of four, top right. Labels stay short (R1-R8, then W1-W10) so a row
/// stays right of the read-probe web view.
struct ReadFillButtons: View {
    let fill: (Int) -> Void

    var body: some View {
        let count = ReadDrafts.all.count
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(0..<((count + 3) / 4), id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { col in
                        let i = row * 4 + col
                        if i < count {
                            Button(Self.label(i)) { fill(i) }
                                .font(.caption)
                                .accessibilityIdentifier("rfill-\(i + 1)")
                        }
                    }
                }
            }
        }
    }

    static func label(_ i: Int) -> String {
        i < 8 ? "R\(i + 1)" : "W\(i - 7)"
    }
}

/// `-screen readweb`: read-probe.html (a textarea, a contenteditable of <div> lines, a Lexical-like contenteditable of
/// <p> paragraphs). The page posts lengths, line-feed counts and paragraph tokens only, never text.
struct ReadWebScreen: View {
    @StateObject private var model = WebModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            hostBackground.ignoresSafeArea()
            WebComposer(model: model, page: "read-probe")
                .frame(width: 250, height: 200)
                .padding(.top, 8)
            VStack(alignment: .trailing, spacing: 10) {
                Button("Clear") { model.clear() }
                    .accessibilityIdentifier("clear")
                Button("Dismiss") { model.dismiss() }
                    .accessibilityIdentifier("dismiss")
                Probe(id: "web-state", value: model.state)
                Probe(id: "web-rects", value: model.rects)
                ReadFillButtons { i in model.fill(i) }
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 24)
        }
    }
}
