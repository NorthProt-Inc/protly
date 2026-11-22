import ProtlyCore
import UIKit
import XCTest

/// K2 (campaign 2026-11-17-keyboard-fixes, report P2 "the keyboard height keeps changing";
/// docs/research/2026-11-17-keyboard-diagnosis.md on branch docs/2026-11-17-keyboard-diagnosis). The band above the
/// bar must be the same in every presentation and equal to Apple's, with row 1 where it always was.
///
/// Every shot is measured the way measure.py measures the layout scenarios: the glass top and row 1's top along the
/// column of the second key, band = row 1 - top. Apple's band is measured in this run on Apple's English keyboard
/// (`hb-apple`). Each `hb-<path>` item collects the shots of one path across the sections and PASSes only when every
/// shot is on Protly, its band is within `bandTolerance` of Apple's and row 1 is within `bandTolerance` of `row1`.
/// Each shot also logs `HEIGHT <id> <n> ...` and `MARK <id>-<n> <epoch>` in ui-log.txt, so the keyboard's own height
/// log (keyboard-log.txt) lines up by time. A shot also records iOS's own placeholder for the keyboard on the host's
/// side (`/ph<top>+<height>`, the element `inputView`): 17 pt shorter than Protly's view (plus the dock) when iOS
/// draws no margin above the keyboard, Protly's full height when it does. The keyboard cannot see it; the test can.
/// A relaunch that came up on another keyboard and picked Protly from the globe list is marked `/picked`. Records
/// only lengths, counts and timings.
extension PhoneRun {
    /// The same order as checks.py's HEIGHT_IDS.
    static let heightIDs = ["hb-apple", "hb-launch", "hb-hide-fresh", "hb-globe", "hb-hide-globe", "hb-emoji",
                            "hb-hide-emoji", "hb-switch", "hb-hide-switch", "hb-switch-hidden", "hb-kill-up",
                            "hb-kill-hidden", "hb-card", "hb-cancel"]
    static let heightArguments = ["-fills", Stub.draft("ok")]
    /// measure.py's BAND_TOLERANCE.
    static let bandTolerance: CGFloat = 1.0
    /// Row 1's top on the iPhone 13 Pro in every layout scenario since Sprint 5 (measure.txt, 02-07: 564.00).
    static let row1: CGFloat = 564
    /// How long the host stays in the background with the keyboard hidden: longer than HostLook's expiry, as leaving
    /// for another app usually is (HostLook, rule 5). A quicker round trip is a known gap (run 183, hb-r1 and hb-r2).
    static let away = HostLook.hiddenExpiry + 3

    /// One measured screen: glass top and row 1 in points (nil when not found), and which keyboard was up.
    struct HeightShot {
        let top: CGFloat?
        let row1: CGFloat?
        let board: Board
        let reached: Bool
        let screen: XCUIScreenshot
        let placeholder: CGRect?
        var picked = false

        var band: CGFloat? { top.flatMap { t in row1.map { $0 - t } } }

        var text: String {
            func f(_ v: CGFloat?) -> String { v.map { String(format: "%.2f", Double($0)) } ?? "none" }
            return "\(f(band))@\(f(top))/\(f(row1))" + (board == .protly ? "" : "/\(board.rawValue)")
                + (reached ? "" : "/unreached") + (picked ? "/picked" : "")
                + (placeholder.map { "/ph\(f($0.minY))+\(f($0.height))" } ?? "/ph-none")
        }
    }

    func heightChecks() {
        if notReady(PhoneRun.heightIDs) { return }
        var shots: [String: [HeightShot]] = [:]
        func take(_ id: String, _ reached: Bool, settle: TimeInterval = 1.5, picked: Bool = false) {
            shots[id, default: []].append(heightShot(id, (shots[id]?.count ?? 0) + 1, reached: reached,
                                                     settle: settle, picked: picked))
        }
        func launch() {
            let (reached, picked) = heightRelaunch()
            take("hb-launch", reached, picked: picked)
        }
        // Hide/show in a used host is one ID per what used it (`hb-hide-globe`, `-emoji`, `-switch`): iOS's look
        // after a hide/show is the look of the presentation before (HostLook, rule 3).
        // 1. A fresh host, then hide/show in it: 3 with 1 s hidden, 2 with 5 s hidden. Ends with an Emoji round trip
        // from the fresh host.
        launch()
        for hidden in [1.0, 1, 1, 5, 5] { take("hb-hide-fresh", heightRefocus(hidden)) }
        take("hb-emoji", heightEmoji())
        // 2. Apple's English keyboard (the reference band), then Protly picked with the globe right after it, and
        // hide/show in the host that has now shown Apple's keyboard.
        launch()
        for _ in 0..<5 {
            d.switchToEnglish()
            take("hb-apple", d.current() == .english)
            take("hb-globe", d.pick(.protly) || d.cycle(to: .protly, taps: 3))
            take("hb-hide-globe", heightRefocus(1))
        }
        // 3. The Emoji round trip in a used host (after the globe pick), each followed by hide/show.
        launch()
        d.switchToEnglish()
        take("hb-globe", d.pick(.protly) || d.cycle(to: .protly, taps: 3))
        for _ in 0..<5 {
            take("hb-emoji", heightEmoji())
            take("hb-hide-emoji", heightRefocus(1))
        }
        // 4. An app switch back with the keyboard up, each followed by hide/show (a host that has been in the
        // background), then the Emoji round trip after it (the full run's 05-after-second-emoji path).
        launch()
        for hidden in [1.0, 1, 1, 5, 5] {
            take("hb-switch", heightAppSwitch())
            take("hb-hide-switch", heightRefocus(hidden))
        }
        for _ in 0..<3 {
            take("hb-emoji", heightEmoji())
            take("hb-hide-emoji", heightRefocus(1))
        }
        // 5. After iOS's margin look (an app switch with the keyboard up, then hide/show), an app switch with the
        // keyboard hidden, `away` seconds in the background, then the field tapped: no notice reaches the keyboard.
        launch()
        for _ in 0..<5 {
            take("hb-switch", heightAppSwitch())
            take("hb-hide-switch", heightRefocus(1))
            d.dismissKeyboard()
            d.pause(1)
            XCUIDevice.shared.press(.home)
            d.pause(PhoneRun.away)
            d.app.activate()
            d.pause(1)
            d.focusField()
            d.waitOutStandIn()
            take("hb-switch-hidden", d.wait(for: .protly, timeout: 3))
        }
        // 6. The host killed in the background after an app switch with the keyboard up (iOS's margin look), then
        // launched again: left with the keyboard up (`hb-kill-up`) or hidden first (`hb-kill-hidden`).
        for keyboardUp in [true, false] {
            launch()
            for _ in 0..<5 {
                take("hb-switch", heightAppSwitch())
                take(keyboardUp ? "hb-kill-up" : "hb-kill-hidden", heightKill(keyboardUp: keyboardUp))
            }
        }
        // 7. The result card from a stub Translate call and the keys after Cancel, in a fresh host. First one card
        // after an app switch (the 240 pt pin), not judged: runs 159 and 178 could not read the bar's center there,
        // and its tree goes to tree-hb-card-after-switch.txt when that happens again.
        launch()
        if accessReadyQuiet() {
            take("hb-switch", heightAppSwitch())
            heightCard(diagnostic: true) { _, _, _ in }
            launch()
            for _ in 0..<5 { heightCard { take($0, $1, settle: $2) } }
        }
        let apple = shots["hb-apple"] ?? []
        let appleBands = apple.compactMap { $0.board == .english ? $0.band : nil }
        let appleBand = appleBands.isEmpty ? nil : appleBands.sorted()[appleBands.count / 2]
        for id in PhoneRun.heightIDs {
            heightItem(id, shots[id] ?? [], appleBand: appleBand)
        }
    }

    /// Full Access decides whether the stub call can run; the card items FAIL unreadable without it.
    private func accessReadyQuiet() -> Bool {
        guard fullAccessOn else {
            d.log("hb-card: full access not on (\(fullAccessHow))")
            return false
        }
        return true
    }

    private func heightItem(_ id: String, _ list: [HeightShot], appleBand: CGFloat?) {
        let item = Item(id)
        let tol = PhoneRun.bandTolerance
        item.note("shots=\(q(list.map(\.text).joined(separator: ",")))")
        let bands = list.compactMap(\.band)
        if let lo = bands.min(), let hi = bands.max() {
            item.note(String(format: "band=%.2f..%.2f", Double(lo), Double(hi)))
        }
        if id == "hb-apple" {
            if list.count < 5 { item.markUnreadable("\(list.count) shots, want 5 or more") }
            // The reference: Apple's keyboard on every shot, the same band each time.
            let english = list.filter { $0.board == .english && $0.band != nil }
            item.require("apple", english.count == list.count, "\(english.count)/\(list.count) on English with a band")
            if let lo = bands.min(), let hi = bands.max() {
                item.require("spread", hi - lo <= tol, String(format: "%.2f pt", Double(hi - lo)))
            }
            finish(item, record: true, screen: list.first?.screen)
            return
        }
        guard let appleBand else {
            item.markUnreadable("apple band not measured")
            finish(item, screen: list.first?.screen)
            return
        }
        item.note(String(format: "apple=%.2f", Double(appleBand)))
        // A shot that came up on another keyboard (a system stand-in, or iOS bringing back English) cannot show
        // Protly's band: listed, not judged. Fewer than 5 judged shots is unreadable.
        let skipped = list.indices.filter { list[$0].board != .protly }.map { $0 + 1 }
        if !skipped.isEmpty { item.note("skipped=\(skipped.map(String.init).joined(separator: ",")) (not on Protly)") }
        if list.count - skipped.count < 5 {
            item.markUnreadable("\(list.count - skipped.count) shots on Protly, want 5 or more")
        }
        var wrong: [Int] = []
        for (i, s) in list.enumerated() where s.board == .protly {
            // The card covers row 1: its shot is judged by the glass top only (row 1 at 564 puts the top at
            // row1 - appleBand).
            let keys = !(id == "hb-card")
            let topWant = PhoneRun.row1 - appleBand
            let ok: Bool
            if keys {
                ok = s.band.map { abs($0 - appleBand) <= tol } == true
                    && s.row1.map { abs($0 - PhoneRun.row1) <= tol } == true
                    && (id != "hb-cancel" || s.reached)  // Cancel was tapped on a finished card
            } else {
                // A finished card, which covers row 1: no row edge where the keys' row 1 would be (the card's own
                // lines can show as one further down, run 184).
                ok = s.reached && s.row1.map { abs($0 - PhoneRun.row1) > tol } != false
                    && s.top.map { abs($0 - topWant) <= tol } == true
            }
            if !ok { wrong.append(i + 1) }
        }
        item.require("wrong", wrong.isEmpty, wrong.isEmpty ? "0" : wrong.map(String.init).joined(separator: ","))
        finish(item, screen: list.first?.screen)
    }

    /// Reached: Protly is up. Picked: it came up on another keyboard and Protly was picked from the globe list, so
    /// the shot shows the globe path, not a fresh presentation (run 161's hb-launch-2).
    /// iOS brings back the keyboard last used in the host: after a pick, a second launch comes up on Protly itself.
    private func heightRelaunch() -> (reached: Bool, picked: Bool) {
        for attempt in 1...3 {
            d.app.terminate()
            d.launch(arguments: PhoneRun.heightArguments)
            if !d.waitForKeyboard() { d.focusField() }
            d.waitOutStandIn()
            if d.wait(for: .protly, timeout: 3) { return (true, false) }
            d.log("hb-launch: came up on \(d.current().rawValue) (launch \(attempt)), picking Protly")
            if !d.pick(.protly) { _ = d.cycle(to: .protly, taps: 3) }
        }
        return (d.current() == .protly, true)
    }

    /// An app switch with the keyboard up came first. Leaves the host (the keyboard hidden first unless
    /// `keyboardUp`, then `away` seconds in the background), terminates it there and launches it again.
    private func heightKill(keyboardUp: Bool) -> Bool {
        if !keyboardUp {
            d.dismissKeyboard()
            d.pause(1)
        }
        XCUIDevice.shared.press(.home)
        d.pause(keyboardUp ? 2 : PhoneRun.away)
        d.app.terminate()
        d.launch(arguments: PhoneRun.heightArguments)
        if !d.waitForKeyboard() { d.focusField() }
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3)
    }

    /// Hides the keyboard with the host's Dismiss button, waits `hidden` seconds and taps the field again.
    private func heightRefocus(_ hidden: TimeInterval) -> Bool {
        d.dismissKeyboard()
        d.pause(hidden)
        d.focusField()
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3)
    }

    private func heightEmoji() -> Bool {
        d.emojiRoundTrip()
        return d.wait(for: .protly, timeout: 2)
    }

    private func heightAppSwitch() -> Bool {
        XCUIDevice.shared.press(.home)
        d.pause(2)
        d.app.activate()
        if !d.waitForKeyboard() { d.focusField() }
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3)
    }

    /// One stub Translate call: the finished card, then the keys after Cancel.
    /// `diagnostic`: logs whether the call ran and keeps the tree when the bar's center cannot be read.
    private func heightCard(diagnostic: Bool = false, _ take: (String, Bool, TimeInterval) -> Void) {
        let scratch = Item("hb-card")
        d.clearField()
        guard fill(1, Stub.draft("ok"), scratch), tapCenter(want: "English", scratch) != nil else {
            d.log("hb-card\(diagnostic ? " after switch" : ""): no call (\(scratch.evidence))")
            if diagnostic { d.dumpOnce("hb-card-after-switch") }
            return
        }
        if diagnostic {
            d.log("hb-card after switch: the call ran")
            if let v = poll(14, until: { $0.finished("Replace") }).view, let cancel = v.button("Cancel", in: v.card) {
                d.pause(0.6)
                d.point(cancel.frame.midX, cancel.frame.midY).tap()
            }
            return
        }
        let done = poll(14) { $0.finished("Replace") }
        take("hb-card", done.met, 0.7)
        if let v = done.view, let cancel = v.button("Cancel", in: v.card) {
            d.pause(0.6)  // the card's buttons ignore taps for 0.5 s after it appears
            d.point(cancel.frame.midX, cancel.frame.midY).tap()
            take("hb-cancel", true, 1.5)
        } else {
            take("hb-cancel", false, 1.5)
        }
    }

    /// iOS's placeholder for the keyboard on the host's side, in points: nil when there is none.
    private func placeholder() -> CGRect? {
        let element = d.app.otherElements.matching(identifier: "inputView").firstMatch
        guard element.exists else { return nil }
        let frame = element.frame
        return frame.isEmpty ? nil : frame
    }

    /// Measures the screen after `settle`. Saves h-<path>-<n>.png for every shot.
    private func heightShot(_ id: String, _ i: Int, reached: Bool, settle: TimeInterval, picked: Bool = false)
        -> HeightShot {
        d.pause(settle)
        let board = d.current()
        let screen = XCUIScreen.main.screenshot()
        d.mark("\(id)-\(i)")
        var top: CGFloat?
        var row1: CGFloat?
        if let shot = d.screenshot(screen), let t = shot.keyboardTop() {
            top = CGFloat(t) / shot.scale
            row1 = shot.row1Top(below: t, column: d.keyX(row: 0, index: 1))
        }
        var result = HeightShot(top: top, row1: row1, board: board, reached: reached, screen: screen,
                                placeholder: placeholder())
        result.picked = picked
        d.savePNG("h-\(id.dropFirst(3))-\(i < 10 ? "0" : "")\(i)", screen)
        d.log("HEIGHT \(id) \(i) \(result.text)")
        return result
    }
}
