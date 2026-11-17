import UIKit
import XCTest

/// diag/p2-height probe (campaign 2026-11-17-keyboard-diagnosis, never merged). Repeats the presentations that can
/// change the band above the bar and measures each one from a screenshot (the glass top and row 1, measure.py's way).
/// Each shot logs `HEIGHT <id> <n> ...` and a `MARK <id>-<n> <epoch>` in ui-log.txt, so the keyboard's own height log
/// (ProtlyHeight's PROBE lines in keyboard-log.txt) lines up by time. Records only lengths, counts and timings.
extension PhoneRun {
    static let heightIDs = ["h-card", "h-globe", "h-emoji", "h-switch", "h-refocus", "h-relaunch"]
    static let heightArguments = ["-fills", Stub.draft("ok")]

    func heightProbe() {
        if notReady(PhoneRun.heightIDs) { return }
        heightCard()
        heightRepeat("h-globe", 10) {
            // Apple's English keyboard, then Protly from the globe's list (02's "picked" path).
            self.d.switchToEnglish()
            self.d.pause(1)
            return self.d.pick(.protly) || self.d.cycle(to: .protly, taps: 3)
        }
        heightRepeat("h-emoji", 10) {
            self.d.emojiRoundTrip()
            return self.d.wait(for: .protly, timeout: 2)
        }
        heightRepeat("h-switch", 10) {
            // 04's path: the host to the background and back with the keyboard up.
            XCUIDevice.shared.press(.home)
            self.d.pause(2)
            self.d.app.activate()
            if !self.d.waitForKeyboard() { self.d.focusField() }
            self.d.waitOutStandIn()
            return self.d.wait(for: .protly, timeout: 3)
        }
        heightRepeat("h-refocus", 10) {
            // Hide and show in the same host (sending a message, then tapping the field again).
            self.d.dismissKeyboard()
            self.d.pause(1)
            self.d.focusField()
            self.d.waitOutStandIn()
            return self.d.wait(for: .protly, timeout: 3)
        }
        heightRepeat("h-relaunch", 5) {
            // 02's direct path: a fresh host process opens the keyboard at once.
            self.d.app.terminate()
            self.d.launch(arguments: PhoneRun.heightArguments)
            if !self.d.waitForKeyboard() { self.d.focusField() }
            self.d.waitOutStandIn()
            return self.d.wait(for: .protly, timeout: 3)
        }
    }

    /// `n` repeats of `step` (true when Protly was reached), one measured shot after each.
    private func heightRepeat(_ id: String, _ n: Int, _ step: () -> Bool) {
        let item = Item(id)
        var shots: [String] = []
        for i in 1...n {
            let reached = step()
            shots.append(heightShot(id, i, reached: reached))
        }
        item.note("shots=\(q(shots.joined(separator: ",")))")
        let problems = d.takeProblems()
        if !problems.isEmpty { item.note("problems=\(problems.count)") }
        finish(item, record: true)
    }

    /// Measures the screen after `settle`: "<top>/<row1>/<board>" in points. Saves h-<id>-<n>.png for the first shot
    /// and for every shot whose top is not 512.
    @discardableResult
    private func heightShot(_ id: String, _ i: Int, reached: Bool, settle: TimeInterval = 1.5) -> String {
        d.pause(settle)
        let board = d.current()
        let screen = XCUIScreen.main.screenshot()
        d.mark("\(id)-\(i)")
        var top = "none"
        var row1 = "none"
        if let shot = d.screenshot(screen), let t = shot.keyboardTop() {
            top = String(format: "%.2f", Double(CGFloat(t) / shot.scale))
            if let r = shot.row1Top(below: t, column: d.keyX(row: 0, index: 1)) {
                row1 = String(format: "%.2f", Double(r))
            }
        }
        let name = "h-\(id.dropFirst(2))-\(i < 10 ? "0" : "")\(i)"
        if i == 1 || top != "512.00" { d.savePNG(name, screen) }
        d.log("HEIGHT \(id) \(i) board \(board.rawValue) reached \(reached) top \(top) row1 \(row1)")
        return "\(top)/\(row1)/\(board.rawValue)"
    }

    /// One stub Translate call: keys, strip, finished card, keys again after Cancel. The keyboard's band must not move.
    private func heightCard() {
        let id = "h-card"
        guard accessReady([id]) else { return }
        let item = Item(id)
        d.clearField()
        var shots: [String] = []
        shots.append("keys:" + heightShot(id, 1, reached: true))
        guard fill(1, Stub.draft("ok"), item), tapCenter(want: "English", item) != nil else {
            item.note("shots=\(q(shots.joined(separator: ",")))")
            finish(item, record: true)
            return
        }
        shots.append("strip:" + heightShot(id, 2, reached: true, settle: 1.0))
        let done = poll(14) { $0.finished("Replace") }
        item.note("finished=\(done.met ? 1 : 0)")
        shots.append("card:" + heightShot(id, 3, reached: done.met, settle: 0.7))
        if let v = done.view, let cancel = v.button("Cancel", in: v.card) {
            d.pause(0.6)  // the card's buttons ignore taps for 0.5 s after it appears
            d.point(cancel.frame.midX, cancel.frame.midY).tap()
        } else {
            item.note("cancel=none")
        }
        shots.append("after:" + heightShot(id, 4, reached: true))
        item.note("shots=\(q(shots.joined(separator: ",")))")
        finish(item, record: true)
        d.clearField()
    }
}
