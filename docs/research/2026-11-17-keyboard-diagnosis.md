# Keyboard diagnosis (campaign 2026-11-17-keyboard-diagnosis, flight 001)

> **STATUS: DRAFT, IN PROGRESS.** P2, P3 and the Chrome half of P1 are complete. The phone half of P1 and P4 are
> still being analysed: their sections hold what is proven so far and mark the rest as open.

Diagnosis only: nothing here is a fix, and nothing in this flight lands on main. Base: main `ab7ce91` (PR #26), the
build on the owner's phone. Every claim is proven, with a run, a test or a measurement named next to it, or it is
marked as a **guess**.

## Environment and limits

- **CI simulator.** Runner `macos-26`, Xcode 26.6, iOS 26.5 runtime, iPhone 13 Pro. The owner's phone runs iOS 27.2
  and the app links the iOS 27.1 SDK. CI has no iOS 27 runtime, so iOS 27 behaviour is unproven everywhere below.
- **Local tools.** This Linux container has no Swift toolchain, so ProtlyCore was not tested here and every Swift
  probe ran in CI. Chromium with Playwright ran the Chrome probes locally.
- **Published runs.** CI results are published on the orphan branch `ci-shots` under `runs/<sha7>-<run>/`. Read one
  with `git show origin/ci-shots:runs/<dir>/report.txt`.

---

## P1. Translate covers only part of a multi-line draft

**Owner:** "on the phone or in Chrome, with line breaks or in certain cases, the whole draft is not translated."
Asked how often: "different every time". No app or site named.

The laptop tower had already ruled out the model and prompts (30 of 30 live multi-line runs kept every line). This
flight found causes in the read and write paths on both platforms. None of them is in the model.

### P1a. iPhone keyboard

*(Being completed. Proven so far, from `runs/7e031fc-122`:)*

- **Native text views (UIKit `UITextView`, SwiftUI field).** The read carried only the end of the draft, and Replace
  replaced only that end. The start of the draft stayed in the field, untranslated. Same result on every try.

  | Draft (field length / line breaks) | Carried by the read | Field after Replace |
  |---|---|---|
  | 3 paragraphs (70 / 4) | 46 chars, 2 line breaks | 37 chars |
  | 5 paragraphs (318 / 8) | 62 chars, 0 line breaks | 267 chars |
  | long (1518 / 8) | 59 chars, 0 line breaks | 1473 chars |

- **Web fields.** That run could not test them: after a JavaScript fill, the keyboard's proxy context stayed empty.
  This is a limit of the probe, not a finding. A follow-up run types the draft key by key instead.

OPEN: the read-step mechanism, the web hosts, cursor in the middle, the timing lead, tries per host, confidence, the
fix direction and owner checks.

### P1b. Chrome extension

**How it was reproduced.**
- Headless Chromium, Playwright 1.63, `channel: 'chromium'`. Playwright's default headless shell did not start the
  extension's service worker, so that was not used.
- The real unpacked extension was loaded, and local pages were served under the real hostnames with
  `context.route`, so the content scripts inject as they do on the live sites.
- Editors were the real npm packages: Lexical 0.12.6, 0.23.1 and 0.53.0 (rich and plain text), Draft.js 0.11.7 and
  Slate 0.147, plus a textarea, a plain contenteditable, and Gmail markup with no signature, a flat signature, a
  wrapped signature and an expanded quote.
- The API was faked in the service worker: nonblank line k came back as `EN<k>`, keeping the line structure exactly.
- Matrix: 3 and 5 Korean lines; one break, blank lines, pasted, or a break after the last line; cursor at the end, in
  the middle or with a selection; an IME composition left open; replies after 0, 150 or 1500 ms; 10 repeats per
  condition. 2040 trials, 0 harness errors.
- Harness and raw results: branch `diag/p1-chrome`, `probe/p1-chrome/` (`results/per-surface.tsv`,
  `results/*.jsonl`).

**Results.**

| Surface | Multi-line trials | Read whole | Written as translated | What the user sees |
|---|---|---|---|---|
| Gmail, no signature | 140 | 140 | 140 (lines) | preview, correct |
| Gmail, signature or expanded quote (3 layouts) | 420 | 60 (only drafts with an Enter after the last line) | 60 | **preview shown, last line still Korean** (360/360 of the others) |
| Instagram DM, Lexical, Alt+T and Enter | 420 | 400 (the 20 IME+Enter trials never ran) | 0 | "Could not write the translation into the message box. Nothing was sent." |
| WhatsApp, Lexical | 280 | 280 | 0 | same |
| Alt+T, Lexical | 140 | 140 | 0 | "Could not write..." |
| Alt+T, textarea / plain contenteditable | 140 / 140 | all | all | correct |
| Alt+T, Draft.js | 140 | 139 | 0 | React `removeChild` crash, editor gone, card still shows a preview |
| Alt+T, Slate | 140 | 140 | DOM 140, Slate's model 0 | box shows English, the site would send the Korean |
| every surface, single line | 10 each | all | all | correct |

**Root causes found.** Each is confirmed in Chromium against npm editors and **likely** on the live sites, which
were out of reach.

1. **Gmail drops the last line, with no warning.**
   - When it happens: a signature or an expanded quote follows the draft, and the user did not press Enter after
     the last line.
   - Chrome's own editing then leaves the last line in the same `<div>` as the signature or quote. Body before
     Translate: `line1<div>line2</div><div>line3<br>…<div class="gmail_signature">…</div></div>`.
   - `userNodes` (`src/content/gmail/body.js:28`) ends the user's part at the first node that *is or contains* a
     boundary (`isBoundary`, `body.js:7`). So that line is never read, sent or replaced, and it stays Korean.
   - The write check (`src/content/gmail/compose.js:264`) compares only the user's part, so it passes and the card
     shows a normal preview.
   - Evidence: 360/360 trials lost exactly one line. 0/140 lost one with no signature, 0/60 with an Enter after the
     last line, 0/30 on single-line drafts. It depends on whether there is a signature or quote and whether the
     last line ended with Enter, which fits "with line breaks" and "different every time".
2. **Instagram and WhatsApp (Lexical) fail every multi-line write and merge the original onto one line.**
   - `setComposerText` (`src/content/dom.js:104-115`) writes with one `execCommand('insertText', false, text)`.
     Lexical turns that into `selection.insertText`, which does not split lines, so "A1\nB2\nC3" becomes "A1B2C3".
   - The check (`src/content/outgoing.js:155`) catches it and the card says "Could not write…". The restore
     (`outgoing.js:157`) writes the Korean back the same way, so the original also loses its line breaks.
   - Evidence: 680/680 multi-line runs failed and 580 came back merged; 20/20 single-line drafts worked. The write
     probe without the extension gave `A1B2C3` in 24/24 cases across Lexical 0.12.6, 0.23.1 and 0.53.0. The tower
     reran `write-probe.cjs` on Lexical 0.23.1 independently and got the same: DOM and model `A1B2C3`, after both
     Enter and Shift+Enter.
3. **A Lexical draft that ends in a line break gets only its first line replaced.**
   - When it happens: a Shift+Enter after the last line, or in plain-text Lexical an Enter onto an empty last line.
   - After `selectAllChildren` and the 60 ms settle, Lexical's own selection covers only line 1: 2 of 9 characters
     in `select-probe.cjs`. The insert replaces line 1, so the box holds the translation and the Korean at once.
     The restore then garbles the draft.
   - `setComposerText`'s `selectsAll()` (`dom.js:104`) compares the DOM selection with whitespace removed, so it
     does not notice.
   - The same applies to the Alt+T writer on any Lexical site (`src/generic/writer.js:68-73`, restore
     `src/generic/instance.js:196`).

**Ruled out (same harness).**
- **Reads.** Whole on every surface except Gmail with a boundary.
- **Cursor and selection.** No effect.
- **Reply delay.** 0, 150 and 1500 ms gave identical outcomes: no race was seen.
- **IME.** A composition still open at Alt+T was committed and sent whole (Instagram 20/20). Enter during a
  composition sent nothing in 20/20, but that is a harness limit: CDP never fires `compositionend` on Enter.
- **Length caps.** Generic boxes refuse drafts over 8000 characters with a message, messages are capped at 32000,
  and `max_tokens` is 16000 (32000 for Deep). A `max_tokens` stop is an error, never a partial write. Replies are not
  streamed.
- **The `norm` lead.** Lexical leaves no whitespace, so `norm` sees the difference and the check fails. `norm` only
  hides changes in the number of blank lines, seen on plain contenteditable and Gmail without a signature.

**Fix direction.**
- **Gmail:** decide the user's part by its position in the text, not by top-level nodes. Split a block that holds a
  boundary at the boundary for read, replace and verify, and fail the check if a typed line is left outside the
  replaced part.
- **Lexical:** never write multi-line text with one `insertText`. A synthetic `text/plain` paste kept every line in
  Lexical, Draft.js and Slate (`write-methods.cjs`), but it must be confirmed on the live sites first (owner check
  P1b-1c).
- **All editors:** check the select-all against the editor's own text, never restore through the lossy path,
  compare line structure (nonblank lines in order) in the verify, and do not treat a DOM-only match as proof for
  Draft.js and Slate.

**Owner checks (Chrome).**
1. **Instagram or WhatsApp Web, extension not involved.** Open a DM with a test account, click the message box, type
   `가나`, Shift+Enter, `다라`. Open View > Developer > JavaScript Console.
   - a. Run the insert snippet in the appendix. Report the printed line: `"A1B2C3"` means the breaks were dropped,
     as in the probe; `"A1\nB2\nC3"` means they were kept.
   - b. Clear the box. Type the two lines and end with a Shift+Enter. Run the snippet with `'X1'`. Report the line.
   - c. Clear the box, type the two lines, run the paste snippet. Report the line.
   - Never press Enter in these steps.
   - d. With protly on, type 3 Korean lines with Shift+Enter between them and press Enter. Report the card's text and
     whether the Korean came back on one line.
2. **Gmail.**
   - Set a signature (Settings > See all settings > General > Signature), or reply in a thread and expand the quote
     with "…".
   - Type 3 Korean lines with no Enter after the last one. Before translating, run the structure snippet in the
     appendix: it prints tag names only, never text.
   - Translate. Report the printed line and whether the last line stayed Korean.
   - Repeat once with an Enter after the last line.

---

## P2. Keyboard height keeps changing

**Owner:** "why does the keyboard height keep changing", and: "constantly, cannot reproduce on demand."

**Reproduction.** Two new filtered runs of the probe method `PhoneChecksUITests/test9_height` (branch
`diag/p2-height`), plus all 81 runs published before this flight.
- Each presentation was repeated, followed by a 1.5 s settle and a screenshot, and measured the way measure.py
  measures: glass top and row 1. The keyboard logged its own geometry as numbers only.
- 70 shots, every one of them on Protly.
- `runs/2b636fe-120`: STATUS measured. A stub card call; globe from English x10; Emoji x10; app switch x10;
  hide/show x10; relaunch x5.
- `runs/13fbf8f-123`: STATUS measured. Each section starts in a fresh host: hide/show, Emoji, English then
  hide/show, app switch then hide/show.

**What changes.** The keys never move: row 1 is at 564 pt in every shot. Only the empty band above the bar changes:

| How the keyboard appeared (iOS 26.5 simulator) | Band above the bar | Shots |
|---|---|---|
| A freshly launched host, and hide/show in it | 52 pt | 5/5 relaunch, 5/5 hide/show |
| Emoji round trip back to Protly (that one presentation only) | 52 pt | 14/14 |
| App switch back with the keyboard up | 52 pt | 12/12 |
| Protly picked with the globe right after Apple's English (US) keyboard | **69 pt** | 11/11 |
| Every hide/show in a host that has been in the background or has shown Apple's keyboard | **69 pt** | 15/15 |
| A stub Translate call: keys, strip, finished card, Cancel | no change | 4 shots at 512 |

**Root cause.**
1. **Our view does not change height.** Confirmed. In every presentation of both runs, the view, its window and
   superview are 257 pt, iOS's own `UIView-Encapsulated-Layout-Height` is 257, and the on-screen frame is
   0,0,390,257 (`keyboard-log.txt`, PROBE lines). This is identical in the 52 and 69 looks. The extra 17 pt is the
   glass iOS draws above the keyboard's height (`hostTopMargin`, `ios-app/Sources/ProtlyKeyboard/ProtlyHeight.swift:12-22`).
   The keyboard cannot see from its own geometry which look it is in.
2. **The host's history decides which look iOS uses.** The pattern is confirmed and was the same every time on the
   simulator. Why iOS works this way is a **guess**.
   - Every presentation is a new controller (`alive 1`, serials c1 to c46) that pins 257.
   - Only the app-switch path sends `NSExtensionHostDidBecomeActive` to the new controller, 0.22-0.41 s after it
     loads (12/12). The pin then drops to 240 and the band is 52 (`ProtlyHeight.swift:107-115`).
   - Hide/show and globe switches never get that notification, so the pin stays at 257 and iOS's margin makes the
     band 69.
   - Example from `runs/13fbf8f-123`: c19, an app switch, became active at 0.41 s and its shot measured 512. c20, the
     hide/show right after, got no notification and measured 495.
3. **The earlier flakes fit this pattern.**
   - Scenario 02 at 69 is the "picked after English" path in 10 of 11 history runs.
   - Scenario 04 at 69 is the notification race noted in run 59.
   - Across all earlier runs, `typing: keyboard top` read 495 in 1335 of 1556 typing starts in test1_68.

   An earlier reading that "the drop stopped firing after run 65" was wrong: `run-shots.sh` kept only the last 30
   minutes of the keyboard log, so from run 40 on the full runs' logs started after the layout test.

**Which change the owner most likely sees all the time:** likely, not proven on iOS 27.2. Messaging apps stay alive
in the background and come back many times. In such an app, every ordinary keyboard open has the 69 pt band: tap the
field, send, tap again. It is 52 only right after an app switch, an Emoji round trip, or in a freshly launched app.
So the band flips between two heights in a way that looks random from the outside, which matches "constantly,
cannot reproduce on demand".

**Ruled out.**
- **Bar vs progress strip.** Both have the same fixed band (`ProtlyBar.swift:40`, `ProgressStrip.swift:75`).
- **Result card and panels.** They are an overlay at `layoutHeight` (`KeyboardViewController.swift:839-857`). Run
  120's `h-card` shots measured 512 throughout.
- **KeyboardKit's toolbar.** It is always shown, because Protly never uses `.emojiSearch`
  (`Vendor/KeyboardKit/Sources/KeyboardKit/_Keyboard/KeyboardView.swift:276-281`).
- **123 and symbol layers.** Same row heights (`ProtlyLayout.swift:24-29`).
- **Several live controllers or a stale 240 pin.** Never seen.
- **Alerts over a live keyboard.** 228 log lines, always kept at 257.
- **The web form accessory bar.** It is a separate host view: it moves the glass 58 pt up, and the +17 comes on top
  of it independently.

**Not covered.**
- iOS 27.2: no CI runtime. Sprint 5 saw a 17.5 pt margin on the phone.
- Landscape: the CI host is portrait only, and the pin is off in landscape (`ProtlyHeight.swift:77`).
- Control Center, Face ID, dictation, and real apps.

**Confidence:** **confirmed** on the iOS 26.5 simulator (70 shots, the same result each time); **likely** on the
owner's phone.

**Fix direction.** A notification-driven pin can never be right for hide/show and globe switches, because those
paths get no notification and the keyboard cannot measure the margin. Pick the state iOS 27 uses most: on the
simulator, every presentation in a used host except the first one after an app switch or Emoji. Pin to that state,
for example 240 always with iOS's margin forming the band. Then check what the fresh-host and Emoji cases look like
on iOS 27. Alternatively, let iOS size the input view. Either way, the owner checks below on iOS 27.2 come first.

**Owner checks (iPhone).**
1. Open Messages and tap the text field. Note the empty space between the top of the keyboard and the bar's text.
2. Swipe the keyboard down, or tap Send, then tap the field again. Do this 3 times. Report whether the space is
   taller from the second open on.
3. Swipe up to the Home Screen, then open Messages again with the keyboard up. Report whether the space is shorter
   now. Hide and show once more and report again.
4. Force-quit Messages: swipe it away in the App Switcher. Open it and tap the field twice, hiding the keyboard in
   between. Report whether the space stays short.
5. Optional, with a Mac: open Console, select the iPhone, filter on subsystem `com.northprot.protly`, category
   `height`, with Action > Include Debug Messages on. Report the numbers on the `bounds` and `host became active`
   lines.

---

## P3. The loading glow on the progress strip does not move

**Owner:** "the loading bar at the top" is "not working right now"; asked whether it was removed.

**Root cause: confirmed. Reduce Motion is on, on the owner's phone (owner's answer, relayed by the laptop tower).**
`StripGlow` pauses its `TimelineView` and centres the band under Reduce Motion by design
(`ios-app/Sources/ProtlyKeyboard/ProgressStrip.swift:104`, `:111-113`). There is no code fault and no fix.

Checked before the owner answered, using published screenshots only and no CI runs:
- **The band is on screen.** It sits at y 44.5-46.5 pt of the 46.5 pt bar band, in the gap above row 1, and the card
  overlay never covers it.
- **It is visible in both appearances**, on screenshots `c-card-wait-*` and `c-card-slow` in `runs/ad80027-100`
  to `-116`.
- **It stays up until the result is done**, not just until the first text arrives (`KeyboardViewController.swift:469`,
  `:480`).

---

## P4. Double-space period sometimes fails

**Owner:** "sometimes double-tapping space doesn't turn into a period."

*(Being completed. Proven so far, from `runs/b03b806-121`, method `test5f_space` on `diag/p4-double-space`:)*

- **Confirmed: a space typed by the bar's suggestion does not start the double-space window (lead E).**
  - `pickSuggestion` types its space with `insertText(" ")` (`KeyboardViewController.swift:194-207`), outside the
    action handler. So KeyboardKit's `lastSpaceTap`
    (`Vendor/KeyboardKit/.../_Keyboard/Keyboard+StandardKeyboardBehavior.swift:141`) still holds the user's
    previous space tap.
  - One tap of space after a pick ends in two spaces, but the time since the last space tap is 6.4-14.0 s, over the
    3.0 s window, so there is no period.
  - Evidence: 18/18 failures (pick1, in a UITextView and two kinds of web contenteditable). With two taps after the
    pick, the period comes, 18/18.
- **Confirmed, by design: a second tap held 0.4 s or longer starts the space trackpad and types nothing (lead C).**
  3/3 tries.
- **Ruled out on iOS 26.5.**
  - A (U+00A0): a contenteditable that stores U+00A0 still reported U+0020 U+0020 to the keyboard.
  - B (context lag): every second release already saw the first space.
  - Hangul composition, and fast double taps 46-75 ms apart.

  0 failures in 236 tries across a SwiftUI field, a UITextView, a textarea and two contenteditables, after English
  and after Hangul.

OPEN: run `e0b1b7d` (Apple's keyboard as a control for the pick case, the 3.0 s window, a word after the cursor),
confidence, the fix direction and owner checks.

---

## Option A (P5: decided, not built)

The protly key becomes the action key and the bar's center pill is emptied.
- **P1:** the key starts the same read and Replace (`FieldText.read`), so the native cut-off in P1a goes with it.
  (Being completed.)
- **P2, P3:** no effect.
- **P4:** see P4.

## Probe branches (never merged, never deleted)

- `diag/p1-chrome`: the Chrome harness, editor pages and raw results (`probe/p1-chrome/`).
- `diag/p1-phone-read`: read logging (lengths, line-break counts, timings) in FieldText and Replace, a stub that
  answers with the shape of the request, host read screens, `ReadChecks.swift`.
- `diag/p2-height`: numbers-only PROBE logging in ProtlyHeight, `HeightProbe.swift` (`test9_height`), a 120-minute
  keyboard log.
- `diag/p4-double-space`: the `p4` space log (code points of the last 2 characters, timings), `SpaceChecks.swift`,
  a plain contenteditable on the web page.
- No `diag/p3-glow` branch: P3 needed no probe code.

## CI runs used

So far, all filtered:
- `runs/b03b806-121` (P4)
- `runs/7e031fc-122` (P1 phone)
- `runs/2b636fe-120` and `runs/13fbf8f-123` (P2)

In progress: `3c208a9` (P1 phone, typed drafts) and `e0b1b7d` (P4, second probe). None hung.

## Appendix: owner console snippets (Chrome)

Insert (P1b-1a; for 1b, replace `'A1\nB2\nC3'` with `'X1'`):

```
(async()=>{const el=document.querySelector('div[role="textbox"][contenteditable="true"]');el.focus();getSelection().selectAllChildren(el);await new Promise(r=>setTimeout(r,60));document.execCommand('insertText',false,'A1\nB2\nC3');await new Promise(r=>setTimeout(r,300));console.log(JSON.stringify(el.innerText))})()
```

Paste (P1b-1c):

```
(async()=>{const el=document.querySelector('div[role="textbox"][contenteditable="true"]');el.focus();getSelection().selectAllChildren(el);await new Promise(r=>setTimeout(r,60));const dt=new DataTransfer();dt.setData('text/plain','A1\nB2\nC3');el.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,300));console.log(JSON.stringify(el.innerText))})()
```

Gmail structure, tag names only (P1b-2):

```
const b=document.querySelector('div[role="textbox"][aria-label="Message Body"]');console.log([...b.childNodes].map(n=>n.nodeType===3?'#text':n.nodeName+(n.matches('.gmail_quote,.gmail_signature,.gmail_signature_prefix')?'[boundary]':n.querySelector('.gmail_quote,.gmail_signature,.gmail_signature_prefix')?'[holds-boundary]':'')).join(' '))
```
