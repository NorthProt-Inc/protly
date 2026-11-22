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
        look.appeared(document: document(controller), at: now)
        follow("will appear")
    }

    /// Call from viewDidDisappear.
    static func disappeared(_ controller: KeyboardInputViewController) {
        look.disappeared(document: document(controller))
    }

    /// The field's document, nil while iOS gives none. Swift imports `documentIdentifier` as a non-optional UUID, and
    /// reading it before iOS has a document traps (probe runs 170 and 173: the keyboard never logged a line).
    private static func document(_ controller: KeyboardInputViewController) -> UUID? {
        guard let proxy = controller.textDocumentProxy as? NSObject else { return nil }
        let getter = NSSelectorFromString("documentIdentifier")
        guard proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }

    /// Every live pin takes the height `look` asks for.
    private static func follow(_ reason: String) {
        let height = CGFloat(look.pin(content: Double(portrait)))
        for pin in pins.allObjects where pin.constraint.constant != height {
            pin.constraint.constant = height
            pin.report(reason)
        }
    }

    /// The host's notices, for the whole process. Selector-free blocks: they live as long as the process.
    private static func observeHost() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSExtensionHostDidBecomeActive, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ProtlyHeight.look.hostBecameActive(at: ProtlyHeight.now)
                ProtlyHeight.follow("host became active")
            }
        })
    }

    private init(_ controller: KeyboardInputViewController) {
        let view: UIView = controller.view
        self.view = view
        // 999, not required: iOS's own constraints win during its transitions instead of breaking ours.
        constraint = view.heightAnchor.constraint(equalToConstant: CGFloat(Self.look.pin(content: Double(Self.portrait))))
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
