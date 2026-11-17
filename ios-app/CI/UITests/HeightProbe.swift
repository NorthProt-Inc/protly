import UIKit
import XCTest

/// diag/p2-height probe (campaign 2026-11-17-keyboard-diagnosis, never merged). Repeats the presentations that can
/// change the band above the bar and measures each one from a screenshot (the glass top and row 1, measure.py's way).
/// Each shot logs `HEIGHT <id> <n> ...` and a `MARK <id>-<n> <epoch>` in ui-log.txt, so the keyboard's own height log
/// (ProtlyHeight's PROBE lines in keyboard-log.txt) lines up by time. Records only lengths, counts and timings.
extension PhoneRun {
    static let heightIDs = ["h2-fresh", "h2-emoji", "h2-english", "h2-switch"]
    static let heightArguments = ["-fills", Stub.draft("ok")]

    /// Probe 2 (run 1, runs/2b636fe-120: English->Protly and hide/show after app switches gave +17 every time; Emoji,
    /// app switch and relaunch did not). Each section starts in a fresh host process, so earlier history cannot carry
    /// over: does hide/show alone add the band, and does a band survive hide/show?
    func heightProbe() {
        if notReady(PhoneRun.heightIDs) { return }
        heightSection("h2-fresh", [
            // A fresh host, then hide/show: 3 with 1 s hidden, 2 with 5 s hidden.
            { self.heightRelaunch() },
            { self.heightRefocus(1) }, { self.heightRefocus(1) }, { self.heightRefocus(1) },
            { self.heightRefocus(5) }, { self.heightRefocus(5) },
        ])
        heightSection("h2-emoji", [
            { self.heightRelaunch() },
            { self.d.emojiRoundTrip(); return self.d.wait(for: .protly, timeout: 2) },
            { self.heightRefocus(1) }, { self.heightRefocus(1) },
        ])
        heightSection("h2-english", [
            { self.heightRelaunch() },
            { self.d.switchToEnglish(); self.d.pause(1); return self.d.pick(.protly) || self.d.cycle(to: .protly, taps: 3) },
            { self.heightRefocus(1) }, { self.heightRefocus(1) },
            // Does an Emoji round trip clear a band that came from English?
            { self.d.emojiRoundTrip(); return self.d.wait(for: .protly, timeout: 2) },
            { self.heightRefocus(1) },
        ])
        heightSection("h2-switch", [
            { self.heightRelaunch() },
            { self.heightAppSwitch() },
            { self.heightRefocus(1) },
            { self.heightAppSwitch() },
            { self.heightRefocus(5) },
        ])
    }

    private func heightRelaunch() -> Bool {
        d.app.terminate()
        d.launch(arguments: PhoneRun.heightArguments)
        if !d.waitForKeyboard() { d.focusField() }
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3) || d.pick(.protly)
    }

    /// Hides the keyboard with the host's Dismiss button, waits `hidden` seconds and taps the field again.
    private func heightRefocus(_ hidden: TimeInterval) -> Bool {
        d.dismissKeyboard()
        d.pause(hidden)
        d.focusField()
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3)
    }

    private func heightAppSwitch() -> Bool {
        XCUIDevice.shared.press(.home)
        d.pause(2)
        d.app.activate()
        if !d.waitForKeyboard() { d.focusField() }
        d.waitOutStandIn()
        return d.wait(for: .protly, timeout: 3)
    }

    /// Runs the steps in order, one measured shot after each.
    private func heightSection(_ id: String, _ steps: [@MainActor () -> Bool]) {
        let item = Item(id)
        var shots: [String] = []
        for (i, step) in steps.enumerated() {
            let reached = step()
            shots.append(heightShot(id, i + 1, reached: reached))
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
        let name = "\(id)-\(i < 10 ? "0" : "")\(i)"
        if i == 1 || top != "512.00" { d.savePNG(name, screen) }
        d.log("HEIGHT \(id) \(i) board \(board.rawValue) reached \(reached) top \(top) row1 \(row1)")
        return "\(top)/\(row1)/\(board.rawValue)"
    }
}
