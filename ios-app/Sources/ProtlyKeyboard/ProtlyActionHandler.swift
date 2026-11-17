import KeyboardKit
import os
import ProtlyCore
import UIKit

/// Letters and backspace inside a word go to ProtlyCore's TypingSession; everything else to KeyboardKit,
/// whose text calls the controller intercepts to commit the word first.
final class ProtlyActionHandler: KeyboardAction.StandardActionHandler {
    weak var host: KeyboardViewController?
    /// The space bar trackpad of the drag in progress (typing-fixes 003).
    private var drag = SpaceDrag()

    override func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction, replaced: Bool) {
        // KeyboardKit calls this from button gestures, always on the main thread.
        MainActor.assumeIsolated {
            if action == .space {
                P4Probe.gesture(gesture.rawValue, reading: host?.isReadingField == true,
                                drag: keyboardContext.isSpaceDragGestureActive)
            }
            // The field read is walking the cursor through the text (a few steps, usually well under a second): a key
            // now would land mid-text and join the text sent, so the keys wait. A gesture's end still goes through,
            // so KeyboardKit's drag state and the shift tracking below never keep a press that began before the read.
            if host?.isReadingField == true, gesture != .end { return }
            if action == .space, gesture == .press || gesture == .release || gesture == .end {
                drag.reset()  // a new press or the end of a drag: the next trackpad takes a new snapshot
            }
            if case .shift = action, gesture == .release, let host, host.mode.korean, !host.mode.manualShift,
               keyboardContext.keyboardCase == .uppercased {
                // Auto-capital is invisible on Korean keycaps, so this tap means "shift on" (ㅃㅉㄸ), not off.
                // KeyboardKit's release toggle then goes .lowercased -> .uppercased.
                keyboardContext.keyboardCase = .lowercased
            }
            if !handleInWord(gesture, on: action) {
                super.handle(gesture, on: action, replaced: replaced)
            }
            guard let host else { return }
            var manual = host.mode.manualShift
            if case .shift = action {
                // Shift acts on release; reading it on press would flag an auto-capital as manual.
                if gesture == .release { manual = keyboardContext.keyboardCase.isUppercasedOrCapslocked }
            } else if gesture == .release || (gesture == .press && action == .backspace) {
                // Shift then space/backspace/123: the manual shift is spent, or the next auto-capital
                // sentence start would show ㅃㅉㄸ.
                manual = false
            }
            // @Published fires on every write; an unchanged write would rebuild the keyboard on each key.
            if host.mode.manualShift != manual { host.mode.manualShift = manual }
        }
    }

    /// Once space is held (typing-fixes 003), Protly's SpaceTrackpad moves the cursor instead of KeyboardKit's drag
    /// math, through the controller's adjustTextPosition, which forgets the field model. Other drags keep
    /// KeyboardKit's behaviour.
    override func handleDrag(on action: KeyboardAction, from startLocation: CGPoint, to currentLocation: CGPoint) {
        guard action == .space else {
            super.handleDrag(on: action, from: startLocation, to: currentLocation)
            return
        }
        // KeyboardKit calls this from button gestures, always on the main thread.
        MainActor.assumeIsolated {
            if host?.isReadingField == true { return }  // as in handle: the field read owns the cursor
            guard let host else {
                super.handleDrag(on: action, from: startLocation, to: currentLocation)
                return
            }
            guard keyboardContext.settings.spaceLongPressBehavior.shouldMoveInputCursor,
                  keyboardContext.isSpaceDragGestureActive else {
                drag.reset()  // still holding, or the drag ended: no trackpad yet
                return
            }
            // Read before the commit below, so its work is not counted as drag time (the next move would read fast).
            let now = ProcessInfo.processInfo.systemUptime
            // The first event of a touch commits the word and takes the snapshot; it only sets the start, as in
            // KeyboardKit. A new start location is a new touch, even if a cancelled one sent no release.
            let offset = drag.move(startX: Double(startLocation.x), startY: Double(startLocation.y),
                                   x: Double(currentLocation.x), y: Double(currentLocation.y), time: now,
                                   snapshot: { host.beginSpaceDrag() })
            if offset != 0 { host.adjustTextPosition(by: offset) }
        }
    }

    /// diag/p4-double-space: what KeyboardKit's double-space check saw at each space release (lengths, the code
    /// points of the last two characters, timings; never the field's text).
    override func shouldEndCurrentSentence(after gesture: Keyboard.Gesture, on action: KeyboardAction) -> Bool {
        guard gesture == .release, action == .space else {
            return super.shouldEndCurrentSentence(after: gesture, on: action)
        }
        let proxy = keyboardContext.textDocumentProxy
        let before = proxy.documentContextBeforeInput
        let afterCount = proxy.documentContextAfterInput?.count ?? -1
        let newWord = proxy.isCursorAtNewWord
        let newSentence = proxy.isCursorAtNewSentence
        let closable = (before ?? "").hasSuffix("  ")
        var since = -1.0
        if let standard = behavior as? Keyboard.StandardKeyboardBehavior {
            since = Date().timeIntervalSince(standard.lastSpaceTap)
        }
        let result = super.shouldEndCurrentSentence(after: gesture, on: action)
        P4Probe.release(tail: P4Probe.tail(before), afterCount: afterCount, newWord: newWord,
                        newSentence: newSentence, closable: closable, sinceLastSpaceTap: since, result: result)
        return result
    }

    /// true when protly handled the gesture itself.
    @MainActor
    private func handleInWord(_ gesture: Keyboard.Gesture, on action: KeyboardAction) -> Bool {
        guard let host else { return false }
        switch (gesture, action) {
        // The invisible edge keys beside ㅁ/ㅣ and ㅋ/ㅡ (iPhoneLayoutService adds them) type the same letter.
        case (.release, .character(let cap)), (.release, .characterMargin(let cap)):
            guard let letter = Dubeolsik.letter(forKeycap: cap) else { return false }
            host.typeLetter(letter)
            return true
        case (.press, .backspace), (.repeatPress, .backspace):
            guard host.backspaceInWord() else { return false }
            tryTriggerFeedback(for: gesture, on: action)
            return true
        default:
            return false
        }
    }
}

/// diag/p4-double-space probe log (subsystem com.northprot.protly, category p4; run-shots.sh copies it into
/// keyboard-log.txt). Numbers only: lengths, code points of the last two characters, timings.
enum P4Probe {
    static let log = Logger(subsystem: "com.northprot.protly", category: "p4")
    private static var lastRelease: Double?
    private static var seq = 0

    static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    static var epoch: String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// The length (Characters and UTF-16) and the code points of the last two characters; never the text.
    static func tail(_ s: String?) -> String {
        guard let s else { return "nil" }
        let last = String(s.suffix(2)).unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ",")
        return "len=\(s.count) u16=\(s.utf16.count) last=[\(last)]"
    }

    static func line(_ text: String) {
        log.notice("\(text, privacy: .public)")
    }

    static func gesture(_ name: String, reading: Bool, drag: Bool) {
        let up = String(format: "%.3f", uptime)
        line("p4 gesture \(name) epoch=\(epoch) up=\(up) reading=\(reading) drag=\(drag)")
    }

    static func release(tail: String, afterCount: Int, newWord: Bool, newSentence: Bool, closable: Bool,
                        sinceLastSpaceTap: Double, result: Bool) {
        let now = uptime
        let gap: Double = lastRelease.map { now - $0 } ?? -1
        lastRelease = now
        seq += 1
        let gapText = String(format: "%.3f", gap)
        let sinceText = String(format: "%.3f", sinceLastSpaceTap)
        var text = "p4 release seq=\(seq) epoch=\(epoch) gap=\(gapText) sinceLastSpaceTap=\(sinceText)"
        text += " before{\(tail)} afterLen=\(afterCount) newWord=\(newWord) newSentence=\(newSentence)"
        text += " closable=\(closable) end=\(result)"
        line(text)
    }
}
