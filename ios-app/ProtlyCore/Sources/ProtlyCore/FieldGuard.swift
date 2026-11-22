import Foundation

// Whether the field still holds what protly read or inserted, so Insert and Undo delete only that text.
// The keyboard deletes one character per call, `count` times: a field edited since the read (a paste or a
// cut anywhere, the cursor moved) must stop the edit, not shift it onto the user's own text. Nothing is ever typed
// over a selection (copyOnly).

public enum FieldGuard {
    /// Replace over a whole-field read (K1b): the cursor is at the end, and the before-context is the read text or a
    /// window of its end (the proxy shows at most about 300 units). Text in front of the read text, or after the
    /// cursor, means the field is not what was read.
    public static func canReplace(_ original: String, before: String, after: String) -> Bool {
        after.isEmpty && !original.isEmpty && isEnd(of: original, before)
    }

    /// The check after Replace: the field holds the result, as canReplace checks the read.
    public static func holdsResult(_ result: String, before: String, after: String) -> Bool {
        canReplace(result, before: before, after: after)
    }

    /// Undo of Read's Insert: nothing is selected and the text before the cursor still ends with all of the inserted
    /// text. With text selected, the first delete would take the selection and the next ones the user's text before
    /// it. A window of the insert's end is not enough: a field that took only part of it (a length limit) shows just
    /// that (tower review of f0533ae: Undo would delete the user's own text).
    public static func canUndo(_ inserted: String, before: String, selected: String) -> Bool {
        offersUndo(true, selected: selected) && !inserted.isEmpty && before.hasSuffix(inserted)
    }

    /// Undo of a whole-field Replace (K1b): nothing selected, nothing after the cursor (where Replace left it), and
    /// the text before it all of the result or a window of its end. Only a Replace that the keyboard proved whole
    /// (a walk over the field read exactly the result) offers this Undo, so the window is that field's end, not an
    /// insert the host cut short; a host change since ends Undo (KeyboardViewController.endUndoIfTouched).
    public static func canUndoReplace(_ inserted: String, before: String, after: String, selected: String) -> Bool {
        after.isEmpty && offersUndo(true, selected: selected) && !inserted.isEmpty
            && (before.hasSuffix(inserted) || isEnd(of: inserted, before))
    }

    /// Replace's insert goes to the field its deletes went to (tower review of f0533ae, bug 4): the field's document
    /// before the deletes and before the insert. Another field means no insert (it would land there; the original field
    /// is left emptied, and the panel offers Copy original). With no document from iOS, nothing better is known.
    public enum Focus: Sendable, Equatable {
        case same, other, unknown

        /// For the `replace` log line: 1 another field, 0 the same, -1 no document from iOS.
        public var logValue: Int {
            switch self {
            case .same: 0
            case .other: 1
            case .unknown: -1
            }
        }
    }

    public static func focus(before: UUID?, now: UUID?) -> Focus {
        guard let before, let now else { return .unknown }
        return before == now ? .same : .other
    }

    /// `window` is non-empty and is `text`'s end: by whole characters (canonical equivalence counts), or by UTF-16
    /// units when the window starts inside a character.
    static func isEnd(of text: String, _ window: String) -> Bool {
        guard !window.isEmpty else { return false }
        return text.hasSuffix(window) || (window.utf16.count <= text.utf16.count && text.utf16.reversed().starts(with: window.utf16.reversed()))
    }

    /// The bar offers a pending Undo only while no text is selected (canUndo would refuse it). The rest of canUndo is
    /// left to the tap, which ends Undo when it fails: a web view can report the context late just after the write.
    public static func offersUndo(_ pending: Bool, selected: String) -> Bool {
        pending && selected.isEmpty
    }

    /// Why a result card offers only Copy, never Replace (Translate, Polish) or Insert (Read).
    public enum CopyOnly: Sendable, Equatable {
        /// The text came from a selection, or text is selected now. Protly never types over a selection:
        /// `selectedText` can hold only its start (the first 43 UTF-16 units after a select all of a long draft,
        /// diagnosis P1a cause 3), so no check before the write and no Undo after it can cover the rest.
        case selection
        /// The field no longer holds what the read returned: typed or moved during the call (P10).
        case fieldChanged

        /// The card's line under the result.
        public var message: String {
            switch self {
            case .selection: "Protly does not type over selected text. Copy the result instead."
            case .fieldChanged: "The text changed while this ran. Copy the result instead."
            }
        }
    }

    /// nil when the card may write its result: Replace over the whole-field read, or Insert (Read, `.in`) at the
    /// cursor. `field` is what the proxy reports now; nil when the card opens, while the call still runs, so only where
    /// the text came from decides then (a selection card is copy-only from the start; the field is checked once done).
    public static func copyOnly(_ action: ActionMode, original: String, isSelection: Bool,
                                field: FieldWatch.Observed?) -> CopyOnly? {
        if isSelection { return .selection }
        guard let field else { return nil }
        if action != .in, !canReplace(original, before: field.before, after: field.after) { return .fieldChanged }
        // Selected since the read: the first delete or the insert would take the selection.
        return field.selected.isEmpty ? nil : .selection
    }
}
