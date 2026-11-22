import Foundation

// K2 (docs/research/2026-11-17-keyboard-diagnosis.md, P2: "why does the keyboard height keep changing"). iOS 26 draws
// a third-party keyboard's glass in one of two looks: flush with the keyboard's view, or `hostTopMargin` above it. The
// host's history decides which, never the keyboard's height: a pin of 240, 257, 260 or 274 pt got the same look on
// every path (iOS 26.5 simulator, flight F03 runs 159-174). The keyboard cannot see the look in its own geometry
// (wide probe, runs 159-161). So it keeps what it knows across presentations and pins its view to the content's
// height where it believes iOS draws no margin, and `hostTopMargin` less where it believes iOS does: the band above the
// bar is Apple's 52 pt in both looks, and the rows do not move (the content sits at the view's bottom).
//
// Rules (what the simulator showed; the keyboard process keeps one HostLook for its host):
// 1. The host leaving with the keyboard up shows no margin afterwards, unless it comes back with the keyboard up
//    (rule 2): a relaunch after the host was killed in the background is a fresh host. Leaving is a controller that
//    disappears within `resignWindow` of NSExtensionHostWillResignActive (0.79-1.90 s on the simulator).
//    1b. A controller that went without viewDidDisappear went with its host (terminated in the foreground): the next
//    one is a fresh host.
// 2. The host coming back with the keyboard up, after leaving with it up, shows the margin from then on. Its notice
//    (NSExtensionHostDidBecomeActive) reaches a controller `freshWindow` or younger (0.22-0.41 s after loading), or
//    comes up to `earlyWindow` before the controller loads (32 ms in run 59, 0.62 s in run 184). Without leaving first
//    (Control Center, an alert, Face ID or a notification reply over a live keyboard, a cold launch) iOS keeps its
//    look.
// 3. Hide and show keep the look of the presentation before, while the host stays in the foreground.
// 5. A hide of `hiddenExpiry` or longer shows no margin afterwards. iOS drops its margin when the host goes to the
//    background with the keyboard hidden (run 183, 5/5) or is relaunched after that (5/5), and no notice reaches the
//    keyboard then (runs 177, 183). The keyboard cannot see that background; a long hide stands for it. A guess: on
//    the simulator a hide and show took about 7 s from disappear to load, and leaving for another app and coming back
//    rarely takes less than 10 s. A quicker round trip with the keyboard hidden after the margin look gives a band 17
//    pt short.
// 4. Back from another keyboard shows no margin: the field kept its document (iOS's documentIdentifier) while another
//    keyboard was up. A hide leaves no document (run 177). True after Emoji; after Apple's English keyboard iOS draws
//    the margin, and the keyboard cannot tell the two apart (a guess that Emoji is the one people come back from). A
//    return from leaving (rule 2) is not this.

public struct HostLook: Sendable, Equatable {
    /// The glass iOS 26 draws above a third-party keyboard in its margin look (iOS 26.5 simulator; the phone showed
    /// 17.5 pt in Sprint 5).
    public static let hostTopMargin = 17.0
    /// How soon after loading a controller still counts as attached by the host's return.
    public static let freshWindow = 2.0
    /// How soon before a controller loads the host's return still counts as meant for it (seen: 32 ms in run 59,
    /// 0.62 s in run 184). Only a return after leaving counts, so it can be as wide as `freshWindow`.
    public static let earlyWindow = 2.0
    /// How soon after the resign notice a disappearing controller counts as the host leaving with the keyboard up.
    public static let resignWindow = 3.0
    /// How long the keyboard can stay hidden before the margin look no longer counts (rule 5).
    public static let hiddenExpiry = 10.0

    /// How the field's document at an appearance compares with the one when the last controller disappeared.
    public enum Document: String, Sendable {
        case none, same, other
    }

    /// Whether the keyboard believes iOS draws its margin above the keyboard now.
    public private(set) var margin = false
    /// When the current controller loaded or was shown again (seconds, the keyboard's monotonic clock).
    private var loadedAt: Double?
    private var resignedAt: Double?
    /// The host left with the keyboard up and has not come back with it (rule 1), and when.
    private var leaving = false
    private var leftAt: Double?
    /// When the host came back after leaving, while no controller had loaded for it yet.
    private var returnedAt: Double?
    /// The current controller is the host's return (rule 2), so rule 4 does not apply to it.
    private var cameBack = false
    /// Whether no controller is up: false from an appearance to its disappearance.
    private var endedCleanly = true
    /// The field's document when the last controller disappeared.
    private var lastDocument: UUID?
    /// When the last controller disappeared.
    private var disappearedAt: Double?

    public init() {}

    /// The height to pin the keyboard's view to, for content of `content` pt.
    public func pin(content: Double) -> Double {
        margin ? content - Self.hostTopMargin : content
    }

    /// A new controller loaded.
    public mutating func loaded(at now: Double) {
        if !endedCleanly {  // rule 1b
            margin = false
            leaving = false
            endedCleanly = true
        }
        loadedAt = now
        cameBack = false
        expire(at: now)
        if let back = returnedAt, now >= back, now - back < Self.earlyWindow { arrived() }  // rule 2, early
    }

    /// The controller appears, in the field's `document` (nil when iOS gives none).
    @discardableResult
    public mutating func appeared(document: UUID?, at now: Double) -> Document {
        // Shown again after its fresh window: a new window for the host's return, as a new controller would get.
        if let loadedAt, now - loadedAt >= Self.freshWindow {
            self.loadedAt = now
            expire(at: now)
        }
        endedCleanly = false
        disappearedAt = nil  // up now: rule 5 counts only hidden time
        guard let document else { return .none }
        guard document == lastDocument else { return .other }
        if margin, !leaving, !cameBack { margin = false }  // rule 4
        return .same
    }

    /// NSExtensionHostWillResignActive.
    public mutating func hostWillResignActive(at now: Double) {
        resignedAt = now
    }

    /// NSExtensionHostDidBecomeActive.
    public mutating func hostBecameActive(at now: Double) {
        resignedAt = nil  // a resign that ends here (Control Center, an alert) is not the host leaving
        guard leaving else { return }
        // Only a controller loaded after the leave can be the return.
        if let loadedAt, loadedAt > (leftAt ?? 0), now >= loadedAt, now - loadedAt < Self.freshWindow {
            arrived()
        } else {
            returnedAt = now
        }
    }

    /// The controller disappeared from the field's `document` (viewDidDisappear; nil when iOS gives none).
    public mutating func disappeared(document: UUID?, at now: Double) {
        endedCleanly = true
        lastDocument = document
        disappearedAt = now
        cameBack = false  // only the returning controller's own appearance is the return
        if let resignedAt, now >= resignedAt, now - resignedAt < Self.resignWindow {  // rule 1
            margin = false
            leaving = true
            leftAt = now
            returnedAt = nil
            self.resignedAt = nil
        }
    }

    /// Rule 5: hidden long enough to have been in the background.
    private mutating func expire(at now: Double) {
        if margin, let gone = disappearedAt, now - gone >= Self.hiddenExpiry { margin = false }
    }

    /// The host came back with the keyboard up (rule 2).
    private mutating func arrived() {
        margin = true
        leaving = false
        returnedAt = nil
        cameBack = true
    }
}
