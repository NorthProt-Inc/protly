/// Where Cancel puts the cursor (keyboard-ui 003, P6; K1b). The whole-field read walks the cursor to the end, back to
/// the start and forward again (WholeRead). Each step is recorded when it is sent and counted, by the UTF-16 move it
/// made, once it settled. A step whose move cannot be named makes the position unknown until a walk reaches the
/// field's end again: the first walk to the end fixes how far the end is from where the user had the cursor. The
/// keyboard waits for a step on its way to settle before it puts the cursor back, and moves back only while the
/// before-context still agrees with the one the read left.
public struct CursorReturn: Sendable, Equatable {
    /// The cursor's offset from where the user had it, nil when unknown.
    private var offset: Int? = 0
    /// The field's end, as an offset from where the user had the cursor: set by the first walk that reached it.
    private var end: Int?
    /// The before-context after the last settled step: where the read left the cursor.
    private var at: [UInt16] = []
    private var inFlight = false

    public init() {}

    /// The record still knows where the user had the cursor.
    public var isKnown: Bool { offset != nil }

    /// A step is on its way: wait for it to settle before moving back.
    public var isMoving: Bool { inFlight }

    /// A read starts where the user has the cursor.
    public mutating func begin() { clear() }

    /// A read starts at the cursor, whose before-context is `before`. A Retry from where the last read left the cursor
    /// keeps its offset so Cancel still returns to the user's original place; anywhere else starts a fresh record.
    public mutating func begin(before: String) {
        let now = Array(before.utf16)
        let same = offset != nil && offset != 0 && now.isEmpty == at.isEmpty && WholeRead.agree(now, at, atEnd: true)
        if !same {
            clear()
        } else {
            end = nil
            inFlight = false
        }
    }

    /// The read is about to move the cursor.
    public mutating func sending() { inFlight = true }

    /// The step settled; `moved` is its move in UTF-16 units (0: nothing changed), nil when it cannot be named.
    public mutating func landed(moved: Int?, before: String) {
        offset = offset.flatMap { o in moved.map { o + $0 } }
        at = Array(before.utf16)
        inFlight = false
    }

    /// The read knows where the field's end is from where the user had the cursor.
    public var hasEnd: Bool { end != nil }

    /// A walk forward reached the field's end (a probe there changed nothing). With the position known, that fixes
    /// the end: each step was checked against the contexts, so a known position wins over an earlier end that was
    /// not the end (a host that stalled for the probe; the read is refused then, design review). With the position
    /// lost, the cursor is at the end the last known walk found.
    public mutating func reachedEnd(before: String) {
        if let offset {
            end = offset
        } else {
            offset = end
        }
        at = Array(before.utf16)
        inFlight = false
    }

    /// Nothing to put back: a selection read, Read clipboard, the result replaced the text, or the call ended.
    public mutating func clear() {
        offset = 0
        end = nil
        at = []
        inFlight = false
    }

    /// The move that puts the cursor back, 0 when nothing moved, the position is unknown, or the before-context no
    /// longer agrees with where the read left it (typed or moved since).
    public func back(before: String) -> Int {
        guard let offset, offset != 0 else { return 0 }
        let now = Array(before.utf16)
        // An empty context agrees with any other: only with another empty one (the read stopped at the start).
        guard now.isEmpty == at.isEmpty, WholeRead.agree(now, at, atEnd: true) else { return 0 }
        return -offset
    }
}
