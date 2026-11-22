// The space a pick from the bar types stands in for the next space tap, as the space after a pick does on Apple's
// keyboard (docs/research/2026-11-17-keyboard-diagnosis.md, P4 case E; K4E). Apple, iOS 26.5 simulator: one tap right
// after a pick adds nothing (4/4, `the `), two taps end the sentence (3/3, `the. `). Protly typed the pick's space
// outside KeyboardKit's action handler, so one tap made two spaces (18/18).
//
// Rules:
// 1. A pick waits with what it left: its word and a space right before the cursor, and the text after the cursor.
// 2. The next space release that types (not the end of a trackpad hold) is taken while the field still shows the
//    pick: it types nothing. The keyboard still runs KeyboardKit's flow for it, so the double-space window starts at
//    this tap and a second tap ends the sentence (`the. `). There is no clock here: however long after the pick, the
//    first tap is the pick's space. Every space release ends the pick, taken or not.
// 3. Any other key, a cursor move (the space trackpad), a hide or an action ends it (`end`).
// 4. A host callback ends it when the field no longer shows the pick: the word and its space not right before the
//    cursor, other text after it, or a selection (a sent message, a tap in the text, an edit).
// 5. Within FieldWatch.ownEditWindow of the pick, a context that does not show it is taken as one lagging behind the
//    pick's own writes (callbacks for a keyboard's own edits arrive late; a web view reports the context late), at a
//    callback and at the tap alike. A selection is never lag.

public struct PickSpace: Sendable, Equatable {
    /// The picked word and its space, nil when no pick waits.
    public private(set) var tail: String?
    /// The text after the cursor at the pick.
    public private(set) var after = ""
    /// When the pick wrote (seconds, the keyboard's monotonic clock).
    public private(set) var pickedAt = 0.0

    public init() {}

    public var isWaiting: Bool { tail != nil }

    /// The bar's pick wrote `word` and then a space; `after` is the text after the cursor then.
    public mutating func picked(_ word: String, after: String, at now: Double) {
        tail = word + " "
        self.after = after
        pickedAt = now
    }

    /// Any other key, a cursor move, a hide, an action: the next space types as usual.
    public mutating func end() {
        tail = nil
    }

    /// A host callback (the text or the selection changed).
    public mutating func noticed(_ o: FieldWatch.Observed, now: Double) {
        if isWaiting, !shows(o, now: now) { end() }
    }

    /// A space release. `types` false: it ends a trackpad hold. true when the pick's space takes this tap's place, so
    /// the tap types nothing. Ends the pick either way.
    public mutating func spaceReleased(types: Bool, _ o: FieldWatch.Observed, now: Double) -> Bool {
        defer { end() }
        return types && shows(o, now: now)
    }

    /// The field still shows what the pick left (rules 4 and 5).
    func shows(_ o: FieldWatch.Observed, now: Double) -> Bool {
        guard let tail, o.selected.isEmpty else { return false }
        if now >= pickedAt, now - pickedAt < FieldWatch.ownEditWindow { return true }
        return FieldWatch.plain(o.before).hasSuffix(tail) && FieldWatch.sameHead(o.after, after)
    }
}
