/// Where Cancel puts the cursor (keyboard-ui 003, P6; K1b). The whole-field read walks the cursor to the end, back to
/// the start and forward again (WholeRead). Each step is recorded when it is sent and counted, by the UTF-16 move it
/// made, once it settled. A step whose move cannot be named makes the position unknown until the read confirms the
/// field's end. The keyboard waits for a step on its way to settle before it puts the cursor back, and moves back only
/// while the before-context still agrees with the one the read left.
public struct CursorReturn: Sendable, Equatable {
    /// The cursor's offset from where the user had it, nil when unknown.
    private var offset: Int? = 0
    /// The before-context after the last settled step: where the read left the cursor.
    private var at: [UInt16] = []
    private var inFlight = false

    public init() {}

    /// A step is on its way: wait for it to settle before moving back.
    public var isMoving: Bool { inFlight }

    /// A read starts where the user has the cursor.
    public mutating func begin() { clear() }

    /// The read is about to move the cursor.
    public mutating func sending() { inFlight = true }

    /// The step settled; `moved` is its move in UTF-16 units (0: nothing changed), nil when it cannot be named.
    public mutating func landed(moved: Int?, before: String) {
        offset = offset.flatMap { o in moved.map { o + $0 } }
        at = Array(before.utf16)
        inFlight = false
    }

    /// An accepted read: the cursor is at the field's end, `fromOrigin` units past where the user had it (the first
    /// walk to the end, every step of which fit the contexts).
    public mutating func confirmEnd(fromOrigin: Int, before: String) {
        offset = fromOrigin
        at = Array(before.utf16)
        inFlight = false
    }

    /// Nothing to put back: a selection read, Read clipboard, the result replaced the text, or the call ended.
    public mutating func clear() {
        offset = 0
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
