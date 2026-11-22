import Combine
import Foundation
import KeyboardKit
import ObjectiveC
import os
import ProtlyCore
import UIKit

/// Pins the keyboard's height in portrait so the band above row 1 is Apple's in every presentation (K2,
/// docs/research/2026-11-17-keyboard-diagnosis.md, P2). Landscape keeps iOS's own height: its rows are KeyboardKit's,
/// not ProtlyGeometry's.
///
/// iOS 26 draws its glass flush with the keyboard's view or `HostLook.hostTopMargin` above it, by the host's history
/// (ProtlyCore `HostLook`). The keyboard cannot see which, so one `HostLook` per process keeps what it knows across
/// presentations, and every live controller pins its view to `portrait` or `HostLook.hostTopMargin` less. ProtlyRoot
/// keeps the content at the bottom, so only the empty top of the bar's band goes under iOS's margin.
///
/// Logs the view's height at debug level (subsystem com.northprot.protly, category height): Console on a Mac
/// shows it for the phone, `log show --debug` for the simulator.
@MainActor
final class ProtlyHeight: NSObject {
    /// The bar's band and four rows, the last one trimmed: 257 pt.
    static let portrait = ProtlyGeometry.topBand + ProtlyGeometry.toolbarHeight
        + 4 * ProtlyGeometry.rowPitch - ProtlyGeometry.lastRowTrim

    /// What the keyboard knows about iOS's look in this host: one per keyboard process.
    private static var look = HostLook()
    private static let pins = NSHashTable<ProtlyHeight>.weakObjects()
    private static var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: "com.northprot.protly", category: "height")
    private static var key: UInt8 = 0

    private weak var view: UIView?
    private let constraint: NSLayoutConstraint
    private var orientation: AnyCancellable?
    private var bounds: NSKeyValueObservation?

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Call once from viewDidLoad. The pin lives as long as the controller.
    static func pin(_ controller: KeyboardInputViewController) {
        observeHost()
        look.loaded(at: now)
        let pin = ProtlyHeight(controller)
        pins.add(pin)
        objc_setAssociatedObject(controller, &key, pin, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        pin.report("pinned")
    }

    /// Call from viewWillAppear.
    static func presented(_ controller: KeyboardInputViewController) {
        let match = look.appeared(document: document(controller), at: now)
        follow("will appear, document \(match.rawValue)")
    }

    /// Call from viewDidDisappear.
    static func disappeared(_ controller: KeyboardInputViewController) {
        look.disappeared(document: document(controller), at: now)
        follow("did disappear")
    }

    /// The field's document, nil while iOS gives none. Swift imports `documentIdentifier` as a non-optional UUID, and
    /// reading it before iOS has a document traps (probe runs 170 and 173: the keyboard never logged a line).
    private static func document(_ controller: KeyboardInputViewController) -> UUID? {
        // UIKit's own proxy: KeyboardKit's textDocumentProxy is a preview stand-in with a random document until it
        // syncs.
        guard let proxy = controller.originalTextDocumentProxy as? NSObject else { return nil }
        let getter = NSSelectorFromString("documentIdentifier")
        guard proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }

    /// Every live pin takes the height `look` asks for; each logs the event and the belief (margin 0 or 1).
    private static func follow(_ reason: String) {
        let height = CGFloat(look.pin(content: Double(portrait)))
        for pin in pins.allObjects {
            pin.constraint.constant = height
            pin.report(reason + ", margin " + (look.margin ? "1" : "0"))
        }
    }

    /// The host's notices, for the whole process. Selector-free blocks: they live as long as the process. Ignored
    /// while the live pins are all inactive (landscape keeps iOS's height, and its looks are not measured). With no
    /// live pin a notice still counts: the old controller can be gone before the host's return reaches the new one.
    private static func observeHost() {
        guard observers.isEmpty else { return }
        let notices: [(Notification.Name, String, @Sendable (inout HostLook, Double) -> Void)] = [
            (.NSExtensionHostWillResignActive, "host will resign active", { $0.hostWillResignActive(at: $1) }),
            (.NSExtensionHostDidBecomeActive, "host became active", { $0.hostBecameActive(at: $1) }),
        ]
        for (name, reason, apply) in notices {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let live = ProtlyHeight.pins.allObjects
                    guard live.isEmpty || live.contains(where: { $0.constraint.isActive }) else {
                        return ProtlyHeight.follow(reason + ", not in portrait: ignored")
                    }
                    apply(&ProtlyHeight.look, ProtlyHeight.now)
                    ProtlyHeight.follow(reason)
                }
            })
        }
    }

    private init(_ controller: KeyboardInputViewController) {
        let view: UIView = controller.view
        self.view = view
        // 999, not required: iOS's own constraints win during its transitions instead of breaking ours.
        let height = CGFloat(Self.look.pin(content: Double(Self.portrait)))
        constraint = view.heightAnchor.constraint(equalToConstant: height)
        constraint.priority = UILayoutPriority(999)
        super.init()

        orientation = controller.state.keyboardContext.$interfaceOrientation.sink { [weak self] value in
            MainActor.assumeIsolated {
                self?.constraint.isActive = value.isPortrait
                self?.report("orientation \(value.rawValue)")
            }
        }
        bounds = view.layer.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue?.height != change.newValue?.height else { return }
            MainActor.assumeIsolated { self?.report("bounds") }
        }
    }

    private func report(_ reason: String) {
        guard let view else { return }
        let height = Double(view.bounds.height)
        let window = Double(view.window?.bounds.height ?? -1)
        let pin = Double(constraint.constant)
        let active = constraint.isActive
        Self.log.debug("\(reason, privacy: .public): height \(height, privacy: .public) window \(window, privacy: .public) pin \(pin, privacy: .public) active \(active, privacy: .public)")
    }
}
