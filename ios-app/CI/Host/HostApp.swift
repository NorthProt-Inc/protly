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
///   appended to Documents/web-events.txt, which run-shots.sh copies into the run folder. `-caret 1` loads the page
///   with `?caret=1`, which also posts the state when the caret moves (fix/double-space-period, test5f_period only).
/// - `readweb`: the whole-field read page (K1b, test5h_wholeweb): a textarea and a Lexical-shaped field, from the
///   bundled read-probe.html, with the whole-read draft buttons (WholeDrafts).
/// `-wholefills 1` adds the whole-read draft buttons (`rfill-1` ... , WholeDrafts) and their select-all and resync
/// buttons to the default screen and the `uikit` screen (K1b, test5g_wholenative).
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
    /// K1b (`-wholefills 1`): a UTF-16 selection the host asks the field for (a fill's cursor, select all).
    @State private var selectRequest: NSRange?
    /// K1b: the SwiftUI field's selection as `location,length` in UTF-16 units (SelectingField), as the UITextView
    /// screen's `sel` probe; empty before iOS 18 or without a selection.
    @State private var selection = ""
    private let fills = (UserDefaults.standard.string(forKey: "fills") ?? "").split(separator: "|").map(String.init)

    /// With `-wholefills 1` on iOS 18 and later the field's selection is bound (SelectingField); else as always.
    private var field: AnyView {
        if #available(iOS 18.0, *), WholeDrafts.enabled {
            return AnyView(styled(SelectingField(text: $text, request: $selectRequest, probe: $selection)))
        }
        return AnyView(styled(TextField("", text: $text, axis: .vertical)))
    }

    private func styled(_ f: some View) -> some View {
        f.lineLimit(1...3)
            .focused($focused)
            .accessibilityIdentifier("field")
            .foregroundStyle(.white)
            .frame(width: 200, alignment: .leading)
            .padding(.leading, 16)
            .padding(.top, 24)
    }

    /// A whole-read draft; its cursor (or, for select all, the whole text) is asked for once the field has the text.
    private func fill(_ i: Int) {
        let draft = WholeDrafts.all[i]
        if text != draft.text { text = draft.text }
        let range = NSRange(location: draft.cursor, length: 0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            selectRequest = range
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            hostBackground.ignoresSafeArea()
            // The field stays in the top-left so the center column below it is only background.
            field
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
                if WholeDrafts.enabled {
                    HStack(spacing: 10) {
                        // Select all on the first draft's text (wr-swiftui-sel), as Select All in the edit menu would.
                        Button("SelAll") { selectRequest = NSRange(location: 0, length: text.utf16.count) }
                            .font(.caption)
                            .accessibilityIdentifier("rselall")
                        Button("SelHead") { selectRequest = WholeDrafts.headRange(text) }
                            .font(.caption)
                            .accessibilityIdentifier("rselhead")
                        // After Dismiss: the field takes the focus again without a tap (the cursor stays).
                        Button("Focus") { focused = true }
                            .font(.caption)
                            .accessibilityIdentifier("rfocus")
                    }
                    WholeFillButtons { i in fill(i) }
                    Probe(id: "sel", value: selection)
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
    /// `<count>:<t>,<t>,...`: how many times the text changed (UITextView.textDidChangeNotification, the keyboard's
    /// edits) and when the last 16 changes came, in ms of the host's uptime clock. test5f_period reads the spacing of a
    /// double tap's two spaces from it. Counts and times only, never the text.
    @Published var edits = "0:"
    private var editCount = 0
    private var editTimes: [Int] = []
    var editObserver: NSObjectProtocol?
    weak var textView: UITextView?

    func noteEdit() {
        editCount += 1
        editTimes.append(Int((ProcessInfo.processInfo.systemUptime * 1000).rounded()))
        if editTimes.count > 16 { editTimes.removeFirst(editTimes.count - 16) }
        edits = "\(editCount):" + editTimes.map(String.init).joined(separator: ",")
    }

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

    /// K1b: a whole-read draft in the text view, the cursor at its offset, with the input delegate told (as the text
    /// system does for an edit).
    func fill(_ i: Int) {
        guard let tv = textView else { return }
        let draft = WholeDrafts.all[i]
        tv.inputDelegate?.textWillChange(tv)
        tv.text = draft.text
        tv.inputDelegate?.textDidChange(tv)
        select(NSRange(location: draft.cursor, length: 0))
    }

    /// K1b: the whole text selected, as Select All in the edit menu would.
    func selectAll() {
        select(NSRange(location: 0, length: (textView?.text ?? "").utf16.count))
    }

    /// F02c: the field's start up to its first line feed selected (WholeDrafts.headRange).
    func selectHead() {
        select(WholeDrafts.headRange(textView?.text ?? ""))
    }

    /// K1b: the selection set again where it is, with the input delegate told, as when the host moves the caret: the
    /// keyboard's context is the host's again (the resync before a read).
    func resync() {
        guard let tv = textView else { return }
        select(tv.selectedRange)
    }

    private func select(_ range: NSRange) {
        guard let tv = textView else { return }
        tv.inputDelegate?.selectionWillChange(tv)
        tv.selectedRange = range
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
        model.editObserver = NotificationCenter.default.addObserver(
            forName: UITextView.textDidChangeNotification, object: tv, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.noteEdit() }
        }
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
                Probe(id: "edits", value: model.edits)
                if WholeDrafts.enabled {
                    HStack(spacing: 10) {
                        Button("SelAll") { model.selectAll() }
                            .font(.caption)
                            .accessibilityIdentifier("rselall")
                        Button("Sync") { model.resync() }
                            .font(.caption)
                            .accessibilityIdentifier("rsync")
                        Button("SelHead") { model.selectHead() }
                            .font(.caption)
                            .accessibilityIdentifier("rselhead")
                    }
                    WholeFillButtons { i in model.fill(i) }
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

    /// K1b (read-probe.html fill()): a whole-read draft in the page's field that last had focus, the caret at the
    /// draft's cursor.
    func fill(_ i: Int) {
        let draft = WholeDrafts.all[i]
        guard let data = try? JSONEncoder().encode(draft.text), let json = String(data: data, encoding: .utf8) else {
            append("host: fill \(i) not encoded")
            return
        }
        run("fill(\(json), \(draft.cursor))", name: "fill()")
    }

    /// K1b (read-probe.html): the caret back at the last fill's cursor, or the whole field selected.
    func restoreCaret() {
        run("restoreCaret()", name: "restoreCaret()")
    }

    func selectAll() {
        run("selectAllIn()", name: "selectAllIn()")
    }

    /// F02c: the field's start up to its first line feed selected.
    func selectHead() {
        run("selectHeadIn()", name: "selectHeadIn()")
    }

    /// The page's text never goes to the log, only the function's name.
    private func run(_ script: String, name: String) {
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            if let error { self?.append("host: \(name) failed: \(error)") }
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
    /// The bundled page: web-composer, or read-probe (`-screen readweb`).
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
            // `-caret 1` (the period check only): the page also posts its state when the caret moves.
            var target = url
            if UserDefaults.standard.string(forKey: "caret") == "1",
               var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.queryItems = [URLQueryItem(name: "caret", value: "1")]
                target = parts.url ?? url
            }
            web.loadFileURL(target, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let model = model
            let name = page
            Task { @MainActor in model.fail("\(name).html is not in the bundle") }
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

// MARK: - K1b: the whole-field read (`-wholefills 1`, `-screen readweb`)

/// The whole-read drafts (ios-app/CI/UITests/WholeReadChecks.swift WholeChecks.spec names them by `rfill-<n>`). Every
/// draft starts with the CI stub's `read` marker line, so the stub answers with the shape of the text the request
/// carried (StubActionClient: `read <utf16>/<lf>/h<fnv> t<ms>`). The paragraphs are those of the walk-back probe
/// (docs/research/2026-11-21-walk-back-probe.md on diag/p1-walk-back): `\u{00A7}<n> ` and sentences, joined by blank
/// lines. `cursor` is a UTF-16 offset: the end, or the middle of the second paragraph.
enum WholeDrafts {
    struct Draft {
        let name: String
        let text: String
        let cursor: Int
    }

    static var enabled: Bool { UserDefaults.standard.string(forKey: "wholefills") == "1" }

    /// StubActionClient.marker + `read`, on its own line.
    static let marker = "protly-stub read\n"

    static let sentence = "\u{C624}\u{B298} \u{D68C}\u{C758} \u{B0B4}\u{C6A9} \u{C815}\u{B9AC}\u{D574}\u{C11C} \u{BCF4}\u{B0B4}\u{C904}\u{AC8C}."
    /// The mixed sentences take turns: the Korean one, an English one with an emoji (a surrogate pair), a Korean one
    /// with an emoji.
    static let mixed = [sentence, "Send me the notes after the call \u{1F44D}.", "\u{D68C}\u{C758} \u{B05D}\u{B098}\u{ACE0} \u{C804}\u{D654}\u{D560}\u{AC8C} \u{1F642}."]

    enum Kind {
        /// The one sentence repeated (the probe's default drafts).
        case plain
        /// Each sentence numbered `<paragraph>-<sentence> ` (no two stretches read the same).
        case numbered
        /// Numbered, the mixed sentences in turn.
        case mixed
    }

    static func paragraphs(_ count: Int, sentences: Int, _ kind: Kind) -> [String] {
        (1...count).map { k in
            "\u{00A7}\(k) " + (1...sentences).map { j -> String in
                switch kind {
                case .plain: return sentence
                case .numbered: return "\(k)-\(j) " + sentence
                case .mixed: return "\(k)-\(j) " + mixed[(k + j) % 3]
                }
            }.joined(separator: " ")
        }
    }

    static func make(_ name: String, _ paras: [String], mid: Bool = false) -> Draft {
        let text = marker + paras.joined(separator: "\n\n")
        let second = (marker + paras[0] + "\n\n").utf16.count
        return Draft(name: name, text: text, cursor: mid ? second + paras[1].utf16.count / 2 : text.utf16.count)
    }

    /// rfill-1 ... rfill-6. UTF-16 units / line feeds with the marker line (without it: 318, 3230, 14 038, 443, 3958).
    static let all: [Draft] = [
        make("p5", paragraphs(5, sentences: 3, .plain)),  // 335/9
        make("p5mid", paragraphs(5, sentences: 3, .plain), mid: true),  // 335/9, the cursor at 112
        make("xlong", paragraphs(8, sentences: 20, .plain)),  // 3247/15
        make("x14k", paragraphs(8, sentences: 60, .mixed)),  // 14 055/15, 320 emoji
        make("emoji", paragraphs(5, sentences: 3, .mixed)),  // 460/9, 10 emoji
        make("r4k", paragraphs(8, sentences: 20, .numbered)),  // 3975/15: under the read's 4000-unit cap
        // F02c: short drafts the proxy window shows whole (the latency target), and the bug cases. One line each: a
        // native host's window stops at a line feed (run 1b402b4-204 showed 22 of the two-line draft's 39 units).
        Draft(name: "s1", text: short, cursor: short.utf16.count),  // 39/0, under select all's 43-unit selectedText
        Draft(name: "s1mid", text: short, cursor: (inline + "\u{00A7}1 \u{C624}\u{B298} \u{D68C}\u{C758} ").utf16.count),  // 39/0 at 26
        Draft(name: "s3", text: short3, cursor: short3.utf16.count),  // 93/0: three sentences on one line
        // A lone emoji ends the line after a mid-text cursor: the forward walk's last jump leaves exactly one pair.
        Draft(name: "etail", text: short + " \u{1F600}", cursor: (inline + "\u{00A7}1 \u{C624}\u{B298} \u{D68C}\u{C758} ").utf16.count),  // 42/0 at 26
        // The marker on its own line (`rselhead` selects it: a partial selection up to a line feed).
        Draft(name: "s1head", text: head, cursor: head.utf16.count),  // 39/1
    ]

    /// StubActionClient.marker + `read` on the draft's own line: the stub answers any text that starts so.
    static let inline = "protly-stub read "
    /// The marker and one numbered sentence, on one line.
    static let short = inline + "\u{00A7}1 " + sentence
    /// The marker and three sentences on one line, as a chat message.
    static let short3 = short + " Send me the notes after the call. " + sentence
    /// The marker line, then one numbered sentence.
    static let head = marker + "\u{00A7}1 " + sentence

    /// `rselhead`: the field's start up to its first line feed (the marker line) selected, a partial selection that
    /// shows no context on either side.
    static func headRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: Array(text.utf16).firstIndex(of: 10) ?? text.utf16.count)
    }
}

/// Buttons `rfill-1` ... `rfill-6` in rows of three, top right (short labels, so a row stays right of the read page).
struct WholeFillButtons: View {
    let fill: (Int) -> Void

    var body: some View {
        let count = WholeDrafts.all.count
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(0..<((count + 2) / 3), id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { col in
                        let i = row * 3 + col
                        if i < count {
                            Button("R\(i + 1)") { fill(i) }
                                .font(.caption)
                                .accessibilityIdentifier("rfill-\(i + 1)")
                        }
                    }
                }
            }
        }
    }
}

/// K1b (`-wholefills 1`, iOS 18 and later): the default screen's SwiftUI field with its selection bound, so the host
/// can put the cursor inside a fill (wr-swiftui-mid) or select the whole text (wr-swiftui-sel). A request is applied
/// once and then cleared. `probe` is the selection as `location,length` in UTF-16 units, whoever set it (the host or
/// the text system), for HostView's `sel` probe.
@available(iOS 18.0, *)
struct SelectingField: View {
    @Binding var text: String
    @Binding var request: NSRange?
    @Binding var probe: String
    @State private var stored: TextSelection?

    /// Every change of the selection updates the probe on its way in.
    private var selection: Binding<TextSelection?> {
        Binding(get: { stored }, set: { new in
            stored = new
            probe = Self.offsets(new, in: text)
        })
    }

    /// `location,length` in UTF-16 units; `multi` for several ranges, "" for none or indices outside the text.
    static func offsets(_ s: TextSelection?, in text: String) -> String {
        guard let s else { return "" }
        switch s.indices {
        case .selection(let r):
            guard r.lowerBound >= text.startIndex, r.upperBound <= text.endIndex else { return "" }
            let u = text.utf16
            return "\(u.distance(from: u.startIndex, to: r.lowerBound)),\(u.distance(from: r.lowerBound, to: r.upperBound))"
        default:
            return "multi"
        }
    }

    var body: some View {
        TextField("", text: $text, selection: selection, axis: .vertical)
            .onChange(of: request) { _, wanted in
                guard let wanted else { return }
                request = nil
                let u = text.utf16
                guard wanted.location >= 0, wanted.length >= 0, wanted.location + wanted.length <= u.count else { return }
                let start = u.index(u.startIndex, offsetBy: wanted.location)
                let end = u.index(start, offsetBy: wanted.length)
                selection.wrappedValue = wanted.length == 0 ? TextSelection(insertionPoint: start)
                    : TextSelection(range: start..<end)
            }
    }
}

/// `-screen readweb`: read-probe.html (a textarea and a Lexical-shaped contenteditable). The page posts each field's
/// length, line-feed count, hash and caret, never its text.
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
                HStack(spacing: 10) {
                    Button("SelAll") { model.selectAll() }
                        .font(.caption)
                        .accessibilityIdentifier("rselall")
                    Button("Caret") { model.restoreCaret() }
                        .font(.caption)
                        .accessibilityIdentifier("rcaret")
                    Button("SelHead") { model.selectHead() }
                        .font(.caption)
                        .accessibilityIdentifier("rselhead")
                }
                WholeFillButtons { i in model.fill(i) }
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 24)
        }
    }
}
