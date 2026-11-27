import Foundation

/// Whether a host callback (textDidChange, selectionDidChange) soon after protly's own read or write is that read's
/// or write's echo (ignored) or a change by the host or the user (Undo ends; Replace becomes copy-only).
public enum WriteGrace {
    /// A read's own last moves call back within this long after it ended.
    public static let afterRead: TimeInterval = 1

    public static func isReadEcho(elapsed: TimeInterval) -> Bool { elapsed <= afterRead }

    /// A synchronous Replace, Undo or Insert (`deletes` deletes, `inserted` UTF-16 units) may still be landing on the
    /// host: no new field read starts and host callbacks count as the write's own echo until `replaceSettle` passes.
    public static func isOwn(elapsed: TimeInterval, deletes: Int, inserted: Int) -> Bool {
        elapsed <= WholeRead.replaceSettle(deletes: deletes, inserted: inserted)
    }
}
