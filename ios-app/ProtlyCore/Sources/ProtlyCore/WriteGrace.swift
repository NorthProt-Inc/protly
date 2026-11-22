import Foundation

/// K1b: whether a host callback (textDidChange, selectionDidChange) soon after protly's own read or write is that read's
/// or write's echo (ignored) or a change by the host or the user (Undo ends; Replace becomes copy-only). Inside the
/// window a change is not seen: no host signal tells the two apart (tower review of f0533ae, lower priority). The windows
/// are therefore as short as the evidence allows.
public enum WriteGrace {
    /// A read's own last moves call back within this long after it ended.
    public static let afterRead: TimeInterval = 1

    public static func isReadEcho(elapsed: TimeInterval) -> Bool { elapsed <= afterRead }

    /// A callback `elapsed` s after protly wrote `inserted` UTF-16 units. A proven write (Replace or its Undo, whose
    /// check walked the field and read exactly the result once the host had had its time) has landed: only the check's
    /// own last moves call back, within a second. An unproven one (Read's Insert) may still be landing: a second and
    /// 2.5 ms a unit, as WholeRead.replaceSettle's insert term.
    public static func isOwn(elapsed: TimeInterval, inserted: Int, proven: Bool) -> Bool {
        elapsed <= 1 + (proven ? 0 : 0.0025 * Double(inserted))
    }
}
