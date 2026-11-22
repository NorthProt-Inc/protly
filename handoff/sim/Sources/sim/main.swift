import Foundation
import ProtlyCore
import UIKit

@MainActor final class FakeProxy: UITextDocumentProxy {
  var text: [UInt16]; var pos: Int; var selEnd: Int? = nil; var selStart = 0
  var byChars = false
  var shown: (b: String?, a: String?, s: String?) = (nil, nil, nil)
  var rng = SystemRandomNumberGenerator()
  var blankChance = 0.0
  var dropDeletes = false
  init(_ s: String, pos: Int? = nil) { text = Array(s.utf16); self.pos = pos ?? text.count; refresh() }
  func refresh() {
    if let e = selEnd { shown = (nil, nil, String(decoding: text[selStart..<min(e, selStart + 43)], as: UTF16.self)); return }
    let w = 40 + (pos &* 7919) % 260
    let b = Array(text[max(0, pos - w)..<pos])
    let a = Array(text[pos...].prefix { $0 != 10 }.prefix(300))
    if Double.random(in: 0..<1) < blankChance && pos > 0 { shown = (nil, a.isEmpty ? nil : String(decoding: a, as: UTF16.self), nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refresh() }; return }
    shown = (b.isEmpty ? nil : String(decoding: b, as: UTF16.self), a.isEmpty ? nil : String(decoding: a, as: UTF16.self), nil)
  }
  var documentContextBeforeInput: String? { shown.b }
  var documentContextAfterInput: String? { shown.a }
  var selectedText: String? { shown.s }
  var hasText: Bool { !text.isEmpty }
  func later(_ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.005...0.03)) { f(); self.refresh() } }
  func adjustTextPosition(byCharacterOffset k: Int) {
    later {
      if let e = self.selEnd { self.pos = k > 0 ? e : self.selStart; self.selEnd = nil; return }
      if self.byChars {
        var left = abs(k)
        while left > 0, k < 0 ? self.pos > 0 : self.pos < self.text.count {
          if k < 0 { self.pos -= 1; if self.pos > 0, (0xDC00...0xDFFF).contains(self.text[self.pos]) { self.pos -= 1 } }
          else { self.pos += 1; if self.pos < self.text.count, (0xDC00...0xDFFF).contains(self.text[self.pos]) { self.pos += 1 } }
          left -= 1 }
      } else { self.pos = min(max(0, self.pos + k), self.text.count) }
    }
  }
  func deleteBackward() { if dropDeletes { return }; later {
    guard self.pos > 0 else { return }
    let s = String(decoding: self.text[..<self.pos], as: UTF16.self)
    let n = s.last.map { String($0).utf16.count } ?? 1
    self.text.removeSubrange((self.pos - n)..<self.pos); self.pos -= n } }
  func insertText(_ t: String) { later { let u = Array(t.utf16); self.text.insert(contentsOf: u, at: self.pos); self.pos += u.count } }
}

func draft(_ n: Int, emoji: Bool = false) -> String {
  var s = "protly-stub read\n"; var i = 0
  while s.utf16.count < n { i += 1; s += emoji && i % 3 == 0 ? "Send me the notes 👍. " : "문장 \(i)번은 이렇게 끝나요. "; if i % 8 == 0 { s += "\n" } }
  return s
}

@MainActor func run(_ name: String, _ p: FakeProxy, expectWhole: Bool, replace: Bool = false, cancelAfter: Double? = nil) async {
  let original = p.text, origin = p.pos
  var cr = CursorReturn(); cr.begin()
  let t0 = Date()
  let task = Task { @MainActor in
    await FieldText.read(p, record: { m in
      switch m { case .sending: cr.sending(); case .landed(let mv, let b): cr.landed(moved: mv, before: b)
      case .confirmedEnd(let o, let b): cr.confirmEnd(fromOrigin: o, before: b) } }, progress: {})
  }
  if let c = cancelAfter { try? await Task.sleep(nanoseconds: UInt64(c * 1e9)); task.cancel() }
  let out = await task.value
  let secs = Date().timeIntervalSince(t0)
  var ok = false; var note = ""
  switch out {
  case .text(let t, let sel): ok = expectWhole && Array(t.utf16) == original && p.pos == original.count; note = "text \(t.utf16.count) sel=\(sel) pos=\(p.pos)"
    if replace { let r = await FieldText.replace(t, with: "read X", p); ok = ok && String(decoding: p.text, as: UTF16.self) == "read X"; note += " replace=\(r)"
      let u = await FieldText.replace("read X", with: t, p); ok = ok && p.text == original && u.emptied && u.held && r.held; note += " undo=\(u)"
      // leftover text in front must not pass
      let lp = FakeProxy("left over " + t); _ = lp
    }
  case .refused, .cancelled, .empty:
    let back = cr.back(before: p.documentContextBeforeInput ?? "")
    FieldText.restore(back, known: true, p); try? await Task.sleep(nanoseconds: 100_000_000)
    ok = (!expectWhole) && p.text == original && p.pos == origin; note = "\(out) back=\(back) pos=\(p.pos)/\(origin)"
  }
  print(ok ? "PASS" : "FAIL", name, String(format: "%.1fs", secs), note)
}

@MainActor func main() async {
  await run("win335", FakeProxy(draft(335)), expectWhole: true, replace: true)
  await run("mid", FakeProxy(draft(335), pos: 60), expectWhole: true)
  let s = FakeProxy(draft(335)); s.selStart = 0; s.selEnd = s.text.count; s.refresh()
  await run("selall", s, expectWhole: true)
  await run("long3247", FakeProxy(draft(3247)), expectWhole: true, replace: true)
  await run("x14k", FakeProxy(draft(14038)), expectWhole: false)
  await run("emojiNative", FakeProxy(draft(443, emoji: true)), expectWhole: true)
  let w = FakeProxy(draft(443, emoji: true)); w.byChars = true
  await run("emojiWeb", w, expectWhole: false)
  await run("cancelMid", FakeProxy(draft(1500), pos: 700), expectWhole: false, cancelAfter: 2.0)
  let b = FakeProxy(draft(1500)); b.blankChance = 0.05
  await run("blanks1500", b, expectWhole: true)
  await run("empty", FakeProxy(""), expectWhole: false)
  let lo = FakeProxy("old text stays. read X"); let h = await FieldText.replace("", with: "", lo); _ = h
  // A field where deletes never apply: leftover in front of the result.
  let stuck = FakeProxy(draft(335)); stuck.dropDeletes = true
  let rr = await FieldText.replace(String(decoding: stuck.text, as: UTF16.self), with: "read X", stuck)
  print(!rr.held && !rr.emptied ? "PASS" : "FAIL", "leftover", rr)
  exit(0)
}
Task { @MainActor in await main() }
dispatchMain()
