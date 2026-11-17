# Keyboard diagnosis (campaign 2026-11-17-keyboard-diagnosis, flight 001)

> **STATUS: COMPLETE, FOR THE OWNER TO READ.** Every problem has its causes, confidence, fix direction and owner
> checks. Each section marks what the simulator and Chromium could not reach.

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

**How it was reproduced.** Three filtered runs on `diag/p1-phone-read`: `runs/7e031fc-122` (STATUS measured),
`runs/3c208a9-124` (STATUS test-failed: the test hit its 30-minute limit on its last case, every earlier case
recorded) and `runs/28771e2-127` (STATUS measured).
- The keyboard logged every read step, what the read returned, the request, Replace, and the proxy's contexts 50 to
  1000 ms after the read: lengths and line-feed counts only, never text (category `read`).
- On this branch the stub answered every draft with the shape of what the request carried, so each card and each
  Replace shows what the read sent.
- Hosts: a SwiftUI field and a UIKit `UITextView`; in a `WKWebView`, a textarea, a contenteditable and a
  Lexical-shaped contenteditable.
- Drafts: Korean paragraphs (each starts with a `§<n>` token) separated by blank lines or single line feeds, from 70
  to 3230 UTF-16 units; chat lines without punctuation; English; the cursor at the end or in an earlier paragraph;
  select all; filled by the host app, or typed key by key with the Protly keyboard.

**What the read assumes.** `FieldText.read` (`ios-app/Sources/ProtlyKeyboard/FieldText.swift:22-57`) returns the
selection when there is one (`:23`). Otherwise it moves the cursor over the after-context until that is empty
(`:30`), then returns the before-context as the whole field (`:54`). It assumes three things: the before-context
holds everything before the cursor, an empty after-context means the end of the field, and `selectedText` is the
whole selection. On the simulator none of the three held.

**Root causes.** All confirmed on the iOS 26.5 simulator. Every try of a case gave the same result, except one
Lexical-shaped read (cause 5).

1. **The before-context is a window of the last few sentences.** Once the host has sent its own copy of the field
   (filled by the app, the field focused again, the selection set again), the read carried only the end of the draft.
   - The cut-short check (`KeyboardViewController.swift:320`) looks only at the after-context, so it passed. Replace's
     guard (`fieldHolds`, `:491-495`, through `FieldGuard.canReplace`, `FieldGuard.swift:7-9`) checks that the window
     is just before the cursor, so it passed too.
   - Replace then swapped only the window. The start of the draft stayed Korean, and the card's translation covered
     only the window.

   | Draft (cursor at the end) | Field (units / line feeds) | Carried by the read | Tries |
   |---|---|---|---|
   | 3 one-sentence paragraphs, blank lines between | 70 / 4 | 46: the last 2 paragraphs | 9 |
   | the same, ending in a line feed | 71 / 5 | 47: the last 2 paragraphs and the line feed | 4 |
   | 5 paragraphs of 3 sentences | 318 / 8 | 62: the last 3 sentences | 30 |
   | 5 one-sentence lines | 114 / 4 | 45: the last 2 lines | 8 |
   | 5 paragraphs of 15 sentences / 8 paragraphs of 20 | 1518 / 8, 3230 / 14 | 59: the last 3 sentences | 29 |
   | 8 chat lines, no punctuation | 175 / 7 | 43: the last 2 lines | 4 |
   | 12 one-word sentences | 191 / 0 | 175: the last 11 sentences | 4 |
   | 6 twelve-word sentences | 149 / 0 | 24: the last sentence | 4 |
   | one paragraph, no punctuation | 382 / 0 | 300 | 4 |
   | English, 3 paragraphs of 2 sentences | 81 / 4 | 53: the last 2 paragraphs and a line feed | 4 |

   Sources: `runs/7e031fc-122` and `runs/28771e2-127`, SwiftUI field and `UITextView` alike. The tries include the
   SwiftUI cases filled with a mid-text cursor, because the SwiftUI fill leaves the cursor at the end. The
   window ran back to a sentence or line start and held about the last 10 to 16 words. With no sentence end or line
   feed in reach it stopped at 300 units. This rule is read off these drafts; Apple does not document it.
2. **The after-context stops at every line feed, so a cursor in an earlier paragraph ends the read there.** This was
   seen in the `UITextView`. The SwiftUI fill leaves the cursor at the end, so the SwiftUI field was not tested this
   way.
   - The read stopped at the end of the cursor's paragraph or line. Then the window rule above applied. Everything
     after that paragraph was never read or replaced, and the check passed, because the after-context was empty.
   - Cursor in paragraph 2 of 5: only paragraph 2 was replaced; 1, 3, 4 and 5 stayed Korean (10/10). Cursor in
     paragraph 2 of 3: paragraphs 1 and 2 were replaced, 3 stayed (3/3). Cursor in line 2 of 5: lines 1 and 2 were
     replaced (2/2).
   - Cursor in paragraph 1 of 3, separated by blank lines or by single line feeds: only paragraph 1 was read (4/4).
     One-unit probe steps crossed the line break, and the next paragraph showed in the after-context. With single line
     feeds, one step did it (`skipl k=1 after=22`). With a blank line between, the first step landed on the blank line
     and the second showed the next paragraph (`skip k=2 after=22`). At the true end of the field a step changed
     nothing for 0.5 s (`skipend`, 2/2).
   - In the only exception, the cursor sat in a 302-unit paragraph. The after-context ended mid-paragraph twice, and
     the second move never showed within 1 s (`notApplied`). The check caught it and showed "Could not read the whole
     text. Select all, then tap again." (3/3). This was the only case in the three runs where the user is told.
3. **Select all is cut too, and Replace then deletes the rest of the draft.** In the `UITextView`, the host app
   selected all of the text in code (`selectedRange`, with the input delegate told). `selectedText` then held the
   first 43 units, the first two sentences, for drafts of 318, 1518 and 3230 units (6/6, `runs/28771e2-127`).
   - Replace's guard compares `selectedText` with that same 43-unit text, so it passed. Replace typed over the whole
     selection, and the field then held only the reply (6/6).
   - The whole draft was replaced by a translation of its first two sentences.
   - From the code, not run: Undo puts back only the 43 units read (`lastInsert`, `KeyboardViewController.swift:525`;
     `undoInsert`, `:557-569`), so the rest is gone.
   - The cut-short panel itself sends the user here ("Select all, then tap again", `:322`).
   - The edit menu's Select All was not run. Neither was select all in the SwiftUI field or on the web page.
4. **A draft typed key by key in one go was read whole; the same draft after a resync was not.**
   - Typed with the Protly keyboard, the read carried all of it on every host: 17/17 (`runs/3c208a9-124`,
     `runs/28771e2-127`). One of these reads carried 14 extra units (cause 5).
   - The drafts were English on all five hosts and a 69-unit Korean draft in the `UITextView`. The probe typed 81
     English units and the fields held 76; the 5 lost units were not traced.
   - Read again after a resync, the same field gave the window: 48 of 76 English, 42 of 69 Korean, 49 of 76 in the
     web textarea (10/10).
   - A resync here means one of three things: the app set the selection again and told the input delegate; Dismiss,
     then the app focused the field again; or, on the web page, Dismiss, then a tap at the field's end.
   - So whether the read is whole depends on what happened to the field since the keyboard came up. That this is the
     source of "different every time" is a **guess**, the likeliest one.
   - **Guess:** the proxy keeps the text this keyboard typed and replaces it with the host's window when the host
     resyncs. Drafts typed longer than 76 units were not tried, so a long draft typed in one go is open.
5. **Web fields show the keyboard only what it typed itself.**
   - Text the page put in by script was never in the context. The protly key found an empty field and fell back to
     the clipboard ("Copy a message first."): 135/135 tries in `runs/7e031fc-122`, and 4/4 in `runs/28771e2-127`.
   - With one key typed after the fill, the read carried that one key, and Replace replaced only it (45/45,
     `runs/3c208a9-124`).
   - After Dismiss and a tap at the field's end, the page sent its state. The read then carried the last 2 sentences
     (39 of 318 units) in the textarea and the Lexical-shaped field (4/4).
   - A side observation from 1 try out of 2: in the Lexical-shaped field, the first typed read carried 90 units for a
     76-unit field. Its 14 extra units match, by length only, what the keyboard had seen and inserted in the field used
     just before (1 + 13 units). The logs hold no text, so that origin is a **guess**. Real chat pages clear their
     box by script after Send, so the next read could carry the tail of the sent message. That this happens on real
     sites is a **guess**.

**Ruled out.**
- **Timing.** Every move that landed was seen at the first poll, 20 to 33 ms after it was sent (40 moves). The polls
  are 20 ms apart, so the host's real delay is shorter. The 2 s budget ended no read. The contexts were the same at 50,
  150, 300, 600 and 1000 ms after every read: 1735 samples, 0 changes. Waiting longer would not have read more.
- **The request.** Its length and line-feed count matched what the read returned, in all 205 calls. The logs hold no
  text, so lengths are all that was compared.
- **Line-break characters.** No context the keyboard saw held a CR, U+2028 or U+2029. In the contenteditable and the
  Lexical-shaped field, though, the keyboard never saw a line break the page itself sent, so those two are untested.
- **The model and prompts.** The tower had already ruled them out, and the stub replaced the model here.

**Not covered.**
- iOS 27.2 (no CI runtime).
- Real apps: Messages, KakaoTalk and Instagram.
- Paste, dictation, an app switch as the resync, and long drafts typed in one go.

**Confidence:**
- Causes 1 to 3 and 5: **confirmed** on the iOS 26.5 simulator, and **likely** on the owner's phone. Most chat apps'
  native fields are `UITextView`s, but that is a **guess**.
- Cause 4: **confirmed** as a mechanism. Its share of the owner's cases is **open**.

**Fix direction.**
- **The read must find both ends of the field by moving, not by trusting a context.** An empty after-context is the
  end only when one more step changes nothing. A step over a line feed was seen at the first poll (21 to 30 ms),
  while at the end nothing changed for 0.5 s.
- **The start must be found the same way, by walking back.** Walking back was not probed: prove it in CI first.
- **Read a selection by walking too, or Replace never over a selection.** `selectedText` cannot be checked against
  the real selection.
- **Change the cut-short panel's advice.** It must not send users to Select all until a selection read is proven
  whole.
- **Replace and Undo must work on exactly what was read**, with a check after the write that the field holds the
  result. A length limit with a message keeps a long read bounded (the extension refuses over 8000 characters).
- **Where it goes:** all of this is in `FieldText` and its callers, and it lands before or with Option A.

**Owner checks (iPhone, Protly, in the app where it happened, or Messages).**
1. Type 3 short Korean paragraphs, with Return twice between them, in one go. Tap the protly key and Replace. Report
   whether all 3 paragraphs became English.
2. Type the same 3 paragraphs. Swipe to the Home Screen and back, or tap outside the field and back into it at the
   end. Tap the protly key and Replace. Report how many paragraphs became English (cause 1 predicts the last 2
   sentences only).
3. Type the 3 paragraphs, tap in the first paragraph, tap the protly key and Replace. Report which paragraphs changed
   (cause 2 predicts the first only).
4. Type 6 or more sentences, select all and tap the protly key. **Do not tap Replace: tap Cancel.** Report whether the
   card's English covers the whole draft or only its first 2 sentences (cause 3).
5. Type 8 or more Korean sentences in one go, then tap the protly key. Report whether the card covers all of them
   (cause 4, long drafts).
6. Report the app or apps where the partial translation happened, and whether the draft had been typed in one go.

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

**Reproduction.**
- Three filtered runs on `diag/p4-double-space`: `runs/b03b806-121`, `runs/e0b1b7d-125` and `runs/f1fa850-126`. All
  three ended STATUS measured with job success, and none hung.
- A probe log (category `p4`) records what KeyboardKit's double-space check saw at every space release: lengths, the
  code points of the last two characters, the time since the last space, and the result. It holds no field text.
- Hosts: a SwiftUI field, a UITextView, a textarea, a pre-wrap contenteditable, and a normal contenteditable (where
  WebKit stores U+00A0).
- Cases: English and Hangul words; taps at the driver's pace (0.8-1.05 s apart) and coordinate double taps
  (46-75 ms); a pick from the bar; a held second tap; pauses of 1.5, 2.2 and 3.5 s; a word right after the cursor.
- Apple's English keyboard ran as the control. Its coordinate double tap made a period 3/3, so Apple's "." shortcut
  works in this simulator.

**A plain double tap at the end of the text never failed on Protly: 204/204.** The runs found these conditions in
which no period comes:

| Case | Protly | Apple's keyboard | Run |
|---|---|---|---|
| **D. A word right after the cursor** (`world`, cursor before it, type `hello`, double-tap space) | **3/3 fail**: `hello  world` | 0/6 fail: `hello. world` | 125 `pr-word`, 126 `ap-word2`, `ap-word2d` |
| **E. One tap after a word picked from the bar** | 18/18 two spaces, no period | 4/4: the tap adds nothing (`hello `) | 121 `pick1`, 125 `ap-pick1` |
| E. Two taps after a pick | 0/18 fail | 0/3 fail | 121 `pick2`, 126 `ap-pick2` |
| **C. A second tap held 0.4 s or longer** | 3/3: no space typed, by design (space trackpad) | not run | 121 `hold` |
| Two spaces 2.0 s / 2.7 s / 4.0 s apart | 0/3, 0/3, 3/3 fail (the 3.0 s window) | fails from 1.63 s on: its window is shorter, 0.95-1.63 s | 125 `pr-gap-*`, 126 `ap-co-*` |

**Root causes.**
- **D: confirmed, and Apple differs.** The double-space check passes (`end=true`). Then KeyboardKit's
  `UITextDocumentProxy.endSentence` returns without a change because the cursor is not at the end of a word
  (`ios-app/Vendor/KeyboardKit/Sources/KeyboardKit/Proxy/UITextDocumentProxy+Words.swift:47-48`; the log reads
  `atEndOfWord=false`). Protly's override (`ios-app/Sources/ProtlyKeyboard/KeyboardViewController.swift:736-742`)
  calls it as it is. This is the only measured case where Apple makes the period and Protly does not. It is the
  likeliest match for "sometimes" (a **guess**: it needs the owner to be typing in front of existing text).
- **E: confirmed as a mechanism, but it does not make a double tap fail.** `pickSuggestion` types its space with
  `insertText(" ")` (`KeyboardViewController.swift:204`), outside the action handler. So KeyboardKit's `lastSpaceTap`
  (`Keyboard+StandardKeyboardBehavior.swift:141`) is not updated.
  - One tap after a pick leaves two spaces where Apple leaves one.
  - From the code only: when the previous typed space was under 3 s before, that single tap gives a period instead.
    The run-126 probe for this case failed to make the pick (4/4; cause unknown).
- **C: confirmed, by design.** The 0.4 s long press (`SpaceTrackpad.longPressDelay`) turns the space drag on. A
  release while the drag is on has no action (`Vendor/.../KeyboardAction+StandardActionHandler.swift:222-225`,
  `:351-358`), so nothing is typed and the period check never runs. How often a real thumb holds that long is open.
- **G, two thumbs: a guess, untested.** A second finger that lands on space while the first is still down. Each key is
  a single `DragGesture` (`GestureButton.swift:156-170`). XCUITest cannot make overlapping touches.

**Ruled out (iOS 26.5 simulator).**
- **A (U+00A0).** The contenteditable stored U+00A0, but the keyboard read U+0020 U+0020 at every second tap
  (36/36 periods).
- **B (context lag).** The first space was always in the context, at 46 ms as at 1 s.
- **Hangul composition.** 80/80 ko tries passed.
- **Autocorrect.** It is disabled, and no length change was seen.
- **Fast double taps.** 80/80 passed.
- **A stale long-press timer.** Ruled out by the code.
- **Field reads dropping a tap.** A read was never active during a space gesture.
- **The 3.0 s window.** It is longer than Apple's, so it never refuses a period Apple would make.

A and B remain open on iOS 27.2 and in real apps.

**Confidence:**
- D: **confirmed**, and it is a difference from Apple.
- E: **confirmed** as a mechanism, but its link to the owner's words is a **guess**.
- C: **confirmed** by design, but its share of the owner's failures is open.
- Which case is the owner's "sometimes": **open**.

**Fix direction.**
- **D first:** end the sentence when a word follows the cursor, as Apple does (`hello. world`). Do it in Protly's own
  `endSentence` override. If KeyboardKit must change, that goes into `protly.patch` and `VENDORED.md`.
- **Then E:** treat the pick's space like Apple's QuickType space. A tap right after the pick takes its place, and the
  double-space window starts at the pick, so a double tap after a pick gives exactly `the. `. One tap must never end
  the sentence.
- **Leave as they are:** the 3.0 s window and the 0.4 s hold, unless the owner checks show otherwise.

**Owner checks (iPhone, Protly, in Messages; do each 5 times and report how many gave a period).**
1. Type `hello`, then double-tap space with one thumb.
2. Type `hello`, then tap space with the left thumb and right away with the right thumb. This tests G.
3. Type `teh`, tap `the` in the bar's right slot, then tap space once. Report one space, two spaces, or a period.
   Then try a double tap after the pick.
4. Type `hello`, tap space, then press space for about half a second and lift without moving. Report whether a second
   space appears.
5. Type `world`, then tap just before it so the cursor sits before `w`. Type `hello` and double-tap space. Report what
   is between `hello` and `world` (expected: two spaces, which is D).
6. Switch to Apple's keyboard (globe key, English (US)) and repeat checks 3 and 5. Also report whether Settings >
   General > Keyboard > "“.” Shortcut" is on.
7. When it fails in daily use, report:
   - the app;
   - whether there was text after the cursor;
   - whether the word before it was picked from the bar;
   - whether that word was Korean or English.

---

## Option A (P5: decided, not built)

The protly key becomes the action key and the bar's center pill is emptied.
- **P1:** the bar's pill and the protly key already share one path (`act`, `KeyboardViewController.swift:283`;
  `runProtlyKey`, `:548`). So Option A keeps the same read and Replace (`FieldText.read`), and every P1a cause carries
  over unchanged: Option A neither causes nor fixes them. The P1a fix belongs in `FieldText` and lands before or with
  Option A. Its cut-short panel ("Select all, then tap again") must change first (P1a, cause 3).
- **P2, P3:** no effect.
- **P4:** no effect. Option A changes only the center pill and the protly key. The right slot's pick (cause E,
  `pickSuggestion`, `KeyboardViewController.swift:194-205`) and the space key stay as they are.

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

Eight runs, all filtered:
- **P1 phone:** `runs/7e031fc-122`, `runs/3c208a9-124` and `runs/28771e2-127`.
  - `runs/3c208a9-124` ended test-failed: `test5h_readtyped` hit its 30-minute limit on its last case, the second
    try of the filled Lexical draft with a mid-text cursor. Every earlier case recorded.
- **P2:** `runs/2b636fe-120` and `runs/13fbf8f-123`.
- **P4:** `runs/b03b806-121`, `runs/e0b1b7d-125` and `runs/f1fa850-126`.

The other seven ended STATUS measured.

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
