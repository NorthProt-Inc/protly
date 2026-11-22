import Foundation

// K2 (docs/research/2026-11-17-keyboard-diagnosis.md, P2: "why does the keyboard height keep changing"). iOS 26 draws
// a third-party keyboard's glass in one of two looks: flush with the keyboard's view, or `hostTopMargin` above it. The
// host's history decides which, never the keyboard's height: a pin of 240, 257, 260 or 274 pt got the same look on
// every path (iOS 26.5 simulator, flight F03 runs 159-168). The keyboard cannot see the look in its own geometry
// (wide probe, runs 159-161). So it keeps what it knows across presentations and pins its view to the content's
// height where it believes iOS draws no margin, and `hostTopMargin` less where it believes iOS does: the band above the
// bar is Apple's 52 pt in both looks, and the rows do not move (the content sits at the view's bottom).
//
// Rules (what the simulator showed; the keyboard process keeps one HostLook for its host):
// 1. A new host shows no margin. The controller before was never told it disappeared: its host was terminated.
// 2. The host coming back from the background with the keyboard up shows the margin from then on. Its notice
//    (NSExtensionHostDidBecomeActive) reaches a controller `freshWindow` or younger (0.22-0.41 s after loading), or
//    comes up to `earlyWindow` before the controller loads (run 59: 32 ms). Over an older controller (Control Center,
//    an alert, Face ID over a live keyboard) iOS keeps its look.
// 3. Hide and show keep the look of the presentation before.
// 4. Back from another keyboard shows no margin: the field kept its document (iOS's documentIdentifier) while another
//    keyboard was up. True after Emoji; after Apple's English keyboard iOS draws the margin, and the keyboard cannot
//    tell the two apart (a guess that Emoji is the one people come back from). A host return for this controller
//    (rule 2) wins: the field keeps its document across the background too.

public struct HostLook: Sendable, Equatable {
    /// The glass iOS 26 draws above a third-party keyboard in its margin look (iOS 26.5 simulator; the phone showed
    /// 17.5 pt in Sprint 5).
    public static let hostTopMargin = 17.0
    /// How soon after loading a controller still counts as attached by the host's return.
    public static let freshWindow = 2.0
    /// How soon before a controller loads the host's return still counts as meant for it.
    public static let earlyWindow = 0.5

    /// Whether the keyboard believes iOS draws its margin above the keyboard now.
    public private(set) var margin = false
    /// When the current controller loaded (seconds, the keyboard's monotonic clock).
    private var loadedAt: Double?
    /// When the host last came back (any controller saw it).
    private var hostReturnedAt: Double?
    /// Whether the last controller was told it disappeared (false while one is up).
    private var endedCleanly = true
    /// The field's document when the last controller disappeared.
    private var lastDocument: UUID?

    public init() {}

    /// The height to pin the keyboard's view to, for content of `content` pt.
    public func pin(content: Double) -> Double {
        margin ? content - Self.hostTopMargin : content
    }

    /// A new controller loaded.
    public mutating func loaded(at now: Double) {
        if !endedCleanly { margin = false }  // rule 1
        endedCleanly = false
        loadedAt = now
        if let back = hostReturnedAt, now >= back, now - back < Self.earlyWindow { margin = true }  // rule 2, early
    }

    /// The controller appears, in the field's `document` (nil when iOS gives none).
    public mutating func appeared(document: UUID?, at now: Double) {
        // Shown again after its fresh window: a new window for the host's return, as a new controller would get.
        if let loadedAt, now - loadedAt >= Self.freshWindow { self.loadedAt = now }
        if margin, let document, document == lastDocument, !hostReturnedForThisController { margin = false }  // rule 4
    }

    /// The host came back within `earlyWindow` before this controller loaded, or since.
    private var hostReturnedForThisController: Bool {
        guard let back = hostReturnedAt, let loadedAt else { return false }
        return back >= loadedAt - Self.earlyWindow
    }

    /// NSExtensionHostDidBecomeActive.
    public mutating func hostBecameActive(at now: Double) {
        hostReturnedAt = now
        if let loadedAt, now - loadedAt < Self.freshWindow { margin = true }  // rule 2
    }

    /// The controller disappeared from the field's `document` (viewDidDisappear; nil when iOS gives none).
    public mutating func disappeared(document: UUID?) {
        endedCleanly = true
        lastDocument = document
    }
}
