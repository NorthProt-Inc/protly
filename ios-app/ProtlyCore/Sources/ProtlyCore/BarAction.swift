import Foundation

/// What the bar's center slot and the protly key offer (keyboard-ui 001). Decided from the field text with the
/// same rules the request uses (ActionAPI.mode(forDraft:), Languages.prefix(of:)), so the label always names the
/// target the request sends. The view draws `symbol`, the arrow and `title` as separate views: a right-to-left
/// endonym cannot reorder them, and a check that reads the label reads only the words.
public enum BarAction: Hashable, Sendable {
    /// `target` is the language's own name (Languages.endonym), shown as the label.
    case translate(target: String)
    /// `korean`: a "ko:" draft, polished in Korean.
    case polish(korean: Bool)
    case read
    case undo

    /// The pill's SF Symbol name. Translate and Polish show words only: no placeholder art until the brand mark
    /// exists (owner, 2026-10-30).
    public var symbol: String? {
        switch self {
        case .translate, .polish: return nil
        case .read: return "doc.on.clipboard"
        case .undo: return "arrow.uturn.backward"
        }
    }

    /// The protly key always needs a symbol: the action's, else the speech bubble the key had before.
    public var keySymbol: String { symbol ?? "character.bubble" }

    /// An arrow goes between the symbol and the title: only for translate ("→ English").
    public var arrow: Bool {
        if case .translate = self { return true }
        return false
    }

    /// The words of the label, never a glyph.
    public var title: String {
        switch self {
        case .translate(let target): return target
        case .polish(let korean): return korean ? "한 Polish" : "Polish"
        case .read: return "Read"
        case .undo: return "Undo"
        }
    }

    /// For the protly key's accessibilityLabel.
    public var spokenLabel: String {
        switch self {
        case .translate(let target): return "Translate to \(target)"
        case .polish(let korean): return korean ? "Polish Korean" : "Polish"
        case .read: return "Read clipboard"
        case .undo: return "Undo"
        }
    }

    /// The request this action makes; nil for Undo, which makes none.
    public var actionMode: ActionMode? {
        switch self {
        case .translate: return .out
        case .polish: return .fix
        case .read: return .in
        case .undo: return nil
        }
    }

    /// The center slot: Undo after an Insert, else the action that fits the field text, else Read when the field
    /// is empty and new text was copied, else nothing. Decided on the text without notes (Notes.split): a field of
    /// notes only shows what an empty one shows.
    public static func center(text field: String, canUndo: Bool, clipboardIsNew: Bool) -> BarAction? {
        if canUndo { return .undo }
        let text = Notes.split(field).text
        // Blank by JavaScript's \s, as Notes.split trims: the bar shows an action exactly when the request sends one.
        if text.unicodeScalars.allSatisfy(Languages.isSpace) { return clipboardIsNew ? .read : nil }
        switch ActionAPI.mode(forText: text) {
        case .out:
            // As ActionAPI.userMessage: the prefix's language, "ko" never (that is a polish), else English.
            let code = Languages.prefix(of: text).code
            let target = code == "ko" ? "en" : code ?? "en"
            return .translate(target: Languages.endonym(of: target) ?? Languages.name(of: target) ?? "English")
        case .fix:
            return .polish(korean: ActionAPI.koreanPolish(text))
        case .in:
            return .read  // mode(forDraft:) never answers .in
        }
    }

    /// The protly key: the center slot's action, and Read where the slot is empty (the key reads the clipboard on
    /// an empty field).
    public static func protlyKey(text: String, canUndo: Bool, clipboardIsNew: Bool) -> BarAction {
        center(text: text, canUndo: canUndo, clipboardIsNew: clipboardIsNew) ?? .read
    }

    /// The progress strip while the call runs (keyboard-ui 003): "Translating", then the arrow and the title for a
    /// translation. nil for Undo, which makes no call.
    public var progressVerb: String? { progressVerb(deep: false) }

    /// A Deep re-run says so, as the extension does: "Translating deeply", "Polishing deeply". Read is never deep.
    public func progressVerb(deep: Bool) -> String? {
        switch self {
        case .translate: return deep ? "Translating deeply" : "Translating"
        case .polish: return deep ? "Polishing deeply" : "Polishing"
        case .read: return "Reading"
        case .undo: return nil
        }
    }

    /// The strip's second line after 8 s (P5).
    public var slowLine: String? { slowLine(deep: false) }

    public func slowLine(deep: Bool) -> String? {
        progressVerb(deep: deep).map { "Still \($0.lowercased())…" }
    }

    /// The label of a call the keyboard makes, from the text it sends, as the bar would show it.
    public static func call(_ mode: ActionMode, text: String) -> BarAction {
        switch mode {
        case .in: return .read
        case .out, .fix:
            // center(text:) decides from the text; an empty text is never sent, but the label stays the mode's.
            if let action = center(text: text, canUndo: false, clipboardIsNew: false), action.actionMode == mode {
                return action
            }
            return mode == .out ? .translate(target: Languages.endonym(of: "en") ?? "English") : .polish(korean: false)
        }
    }
}
