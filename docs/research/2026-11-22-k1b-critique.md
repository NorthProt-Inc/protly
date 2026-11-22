# K1b critique: the whole-field read (PR #39, `fix/whole-field-read`)

> **STATUS: COMPLETE** (2026-11-22 23:49Z). Independent review, read-only: nothing was changed, run or commented.
> Code refs are `file:line` on `origin/fix/whole-field-read` at `47425f3`. `FieldText.swift` is in
> `ios-app/Sources/ProtlyKeyboard/`, `WholeRead.swift` in `ios-app/ProtlyCore/Sources/ProtlyCore/`, `checks.py` in
> `ios-app/CI/`. Run folders are `runs/<sha7>-<n>` on `origin/ci-shots`.

## Progress

- 23:26Z to 23:40Z: PR, briefs, diagnosis, probe doc and all K1b sources read; runs 222 to 225 read (224 and 225
  are the head's tree); all 541 `read done` lines of the 25 K1b runs tallied; Apple docs checked.
- 23:49Z: all five sections written. Run 226 (the full run on the head) was still running; it is not in here.

## 1. Verdict

- Walking the cursor is essential: it is the only way past the proxy's window, and as **evidence** it is sound.
  As a **proof** it is a dead end. The keyboard can only time the absence of a change, so each proof step is a
  fixed wait, the waits are the latency, and no number of waits is a proof on a host that lags.
- **Do not ship PR #39, and stop fixing it.** Every Translate, Replace and Undo is seconds slower than main by
  design, and the head regressed (native wr- FAILs per round: 14, 6, 2, then 7 on the head).
- **Rework by deletion** (section 4): one pass, accepted only when the host showed no lag, refused fast
  otherwise; Replace and Undo as on main. About half the code, two CI runs, one phone session.
- If "accepted on evidence" is not acceptable, shelve K1b and keep K1a. This API cannot give whole, fast and
  simple together; one of the three has to go.

## 2. Critique

### What 14 hours bought

- 30 commits, 08:37Z to 22:53Z. +4610/-389 in 28 files: shipped code +1554, ProtlyCore tests +1004, CI harness
  +2052. `FieldText.swift` grew from 78 to 671 lines. 60 `keyboard-shots` runs for K1b and its probe since 02:51Z:
  37 failed, 9 cancelled, 9 green, 3 skipped, 2 running. About 27 runner-hours.
- The head (`ae31400-224` native, `597be68-225` web): 7 native wr- FAILs, all on uikit, two of them 41 s and 57 s
  UI timeouts, while swiftui passed 12 of 12 in the same run. Web: 5 FAILs, as in `46fdac6-223`, on other cases.
  In run 224 a 0.5 s probe took 3.5 s (`read st f ... tot=3511`): the verdict follows the runner's lag.
- The best native run (`8e581ae-222`) gives the user: 39 units read in 2.3-2.6 s, 335 units in 5.3-8.3 s, 3247
  units in 12.7-15.7 s, after which Replace locks the keys 17.5-20.6 s and Undo 16.5-18.1 s. A 14 055-unit field
  is refused after 11-15 s. Web, 39 units: 2.4-9.0 s (runs 223, 225).

### Essential (the iOS API forces it)

- The proxy shows a window with no length, no offset and no end flag, so reading past it means moving the cursor
  and reading again: one walk forward, one walk back. Presence is cheap (a move over text shows in 30-50 ms, p50,
  PR body); absence can only be a timeout, and a read needs at least two (the end, the start).
- `safeJump` and the per-step fit check (`WholeRead.swift:76-94`, `:249-299`, `:356-387`): pure and small. In the
  probe "every wrong read had bad>0", so the step check is what catches wrong text.

### Accidental (patch on patch), worst first

1. **The post-Replace proof** (`FieldText.swift:544-592`, `:609-670`): +3.5 s on every Replace and every Undo of
   a 39-unit draft, against 0 on main. It created the hazard it guards against: the check's own cursor moves,
   sent while the host was still deleting, emptied the Lexical-shaped page (run `e070adc-172`, `c90cd63`, `:508-509`).
   The guard is a timer, `1.5 + 0.004 d + 0.0025 i` s, "a bound from measurements, not a signal from the host"
   (`WholeRead.swift:39-45`). In run 222 the native host's last callback had arrived before the insert went out,
   53 ms in; the keyboard then waited 1.7 s for the timer and 1.8 s for the walk. Bug 4 of the tower review (the
   insert landing in another field) exists only because this path put an `await` between the deletes and the
   insert. Main sends both in one go.
2. **The second pass** (B2, R2, FE: `FieldText.swift:456-468`; `WholeRead.swift:178-184`, `:220-229`) doubles every
   read that is not a window proof. In 541 reads, 13 were refused in it: 11 after a B1 with the field's exact
   length and line-feed count, 1 unknown, and **1 real catch** (run 224, 23:04:05Z: B1 stopped at 126 of 335
   units on the stalled runner, with `late=2` in its log). The day's only `disagree` (run 224, 23:05:17Z) had an
   exact B1 (`h=49b6f226`) and a wrong B2.
3. **One wait paid twice.** At a true start the walk waits `emptyWait` inside the step that emptied the context
   (`FieldText.swift:194-202`) and again before the probe (`:158-165`). Run 222: `b1 s=2 k=1 tot=361`, then
   808 ms to the probe's line. That is 0.3 s on every read, Replace check and Undo check, and it is why the PR
   body's breakdown ("emptyWait 0.3 s and the start probe 0.5 s") does not add up to its own B1 times.
4. **Lag patches, one per failed run**: the second look and `slowSeen` (`:179-193`); the rejudge 0.3 s later
   (`:208-220`); false-start and false-end undo, 5 retries each (`:237-254`); the return's wait rule, rewritten
   after each of three runs (`:277-299`); the blank gate (`:565-573`). About 39 comment lines cite a run and 27 a
   review. Every patch waits a lagging host out. None asks whether a read on a lagging host should be trusted.
5. **A modelled host broke the real ones.** `afterFits` (`WholeRead.swift:278-282`) answered a host the
   cross-model review modelled; it was reproduced only on a fake proxy, never on a CI host. It refused 59 of 90
   reads as `b1:badStep` in runs 200, 201, 204 and 205 (at most 12 were meant to be refused) until `eb3b532`.
6. **Special cases and structure**: `collapsed()`, the `bh` walk and the partial-selection proof
   (`WholeRead.swift:165-170`, `FieldText.swift:402-424`) serve one synthetic case, `shead`; five mutable statics
   act as return values (`:302-305`, `:498`, `:503`); `walk()` is 157 lines with a dozen exits (`:111-267`).
7. **About 20 tuned constants** (`WholeRead.swift:14-50`, `:208`, `:315`, `WriteGrace.swift`, `checks.py:90`,
   `:128`), fitted to four synthetic hosts on the iOS 26.5 simulator. The phone runs 27.2 and real apps. No phone
   check of P1a was ever run; the only phone note says the full context was available (`docs/ios-keyboard-notes.md:124`).

### Process

- **"Proven" drove everything, and it was the wrong word.** The briefs said "accepted means exact" and "never show
  an unproven result". No walk can deliver that; the PR's own "Not proven" section lists the holes. A formal goal
  on a channel that cannot be observed turns each flaky run into a new rule.
- **A 38-minute loop with no model of the host.** The matrix is 58 check IDs and 70 tries (`checks.py:72-88`),
  each a read, a Replace and an Undo. A hypothesis cost one run, so runs fanned out on `diag/*` branches and the
  design followed whichever log came back first.
- **The latency gate is red by construction and measures the wrong thing** (`checks.py:90-109`): main + 500 ms on
  first text, card, Replace and Undo, against a stub that answers in 0.4 s. The PR body states floors of 1.8 s
  and 3.5 s. The real API's first update takes 1.5-2.2 s (run `b4101b7-208`), so a 1.5 s read costs nothing there.
- **Reviews only added.** The briefs said "prefer cutting"; every review round's "taken" list is new conditions.

## 3. First principles

**The user needs**: for a draft just typed, English on the card as fast as the API allows; for a multi-line draft
the user went back into, the whole draft or an honest "could not read it", never the last two sentences in
silence (the P1 report); Replace at once, never destroying text, and Undo; for long text any honest path (Copy,
then Read clipboard). Not needed: a proof, 4000-unit fields, web editors on the phone, a walk to prove Undo.

**A keyboard extension knows for sure**: what it sent to the API; every insert and delete it issued; that the text
before the cursor ends with the window, now; that more text exists, once a move shows some. It cannot know the
field's length, whether the window is the whole field, whether a move has landed, whether the host is native or
web, or when the host has finished applying edits. Only the pasteboard hands over a whole text for certain.

| Apple fact | Status |
|---|---|
| The contexts are "textual context before/after the insertion point"; no amount is promised | Verified: `UITextDocumentProxy`, `UIInputViewController`, "Handling text interactions in custom keyboards" |
| No member gives the whole text, a length, a position or an end flag; `selectedText` and `documentIdentifier` exist, with nothing said about truncation | Verified: member lists of both types |
| `adjustTextPosition(byCharacterOffset:)` takes "characters" (unit undefined), returns nothing, has no completion | Verified: reference page |
| `textDidChange` / `selectionDidChange`: "because your keyboard extension doesn't have direct access to the text input field, the argument is `nil`" | Verified: same article |
| A keyboard "cannot select text. Text selection is under the control of the app" | Verified: App Extension Programming Guide |
| Window of the last 2-3 sentences (300 units at most); after-context stops at a line feed; `selectedText` about 43 units | Repo measurement, simulator only. A developer-forum post (thread 772158, 2025, unanswered) reports "only the last two sentences" after a paste in WhatsApp, Signal, Telegram |
| Moves are asynchronous; native hosts move by UTF-16 units, WebKit by characters; web hosts send no callbacks; the proxy mirrors the keyboard's own edits at once (500 units, run 222) | Repo measurements, simulator only; assumptions on the phone |

## 4. One clean solution: one pass, clean or refuse, main's writes

**Product behavior**
- Tap: the call starts at once on the window's text (the speculative call, as built); the read makes one pass; the
  card opens when the read is accepted. A draft typed in one go: card at max(API, about 2 s). A multi-line draft
  the user went back into: 2.5 to 5 s for the read, with the progress line after 2 s.
- Host lagged, field too long for the cap, emoji on a web page, anything that does not fit: refused, cursor back,
  "Could not read the whole text. Copy it, then use Read clipboard." Retry reads again.
- Replace at once; the keys never wait. Undo while nothing is after the cursor and the field still ends with the
  result; a key or a host change ends it. No "Replace may not have finished".
- Selection: K1a. Select all (no context on either side): collapse with +1 and read; text after it means refuse.

**Algorithm**
```
read, capped by time (about 5 s):
  F   walk to the end; on an empty after-context probe +1; no change for 0.5 s is the end
  B1  walk back by jumps shorter than the context; every step must fit; on an empty before-context
      wait 0.3 s once, then probe -1; no change for 0.5 s is the start
  R1  one move forward by B1's length; the contexts must show the end again
  FM  probe +1; it must cross nothing
  accept iff all of that held, B1 ends with what F crossed, and no step was late, blank, undone or misfit
  otherwise refuse: no second look, no rejudge, no retry, no second pass
replace: N deleteBackward and one insertText in one go, as on main; no wait, no walk
```
This is today's window-proof path (`FieldText.swift:429-455`, `WholeRead.swift:134-138`) without the condition
`back1 == window`, with every lag patch turned from "wait longer" into "refuse". The change is deletion.

**Evidence without a new run.** Replay of the existing logs: accept iff walks f, b1 and fm ended `done` with
`retries=0 resyncs=0 late=0` and fm crossed 0 units (phantoms and `lagged` are not logged, so it is approximate).
- Native, 10 filtered runs: accepts 157 of the 169 reads K1b accepted (93%), plus 5 that K1b refused in its second
  pass. Web, 8 runs: 35 of 120 (29%). The lag patches and the second pass pay for two synthetic web pages.
- B1 finished partial 3 times in 541 reads (runs 204, 216, 224). The rule refuses all three: two fail FM, the
  third shows `late`.
- Time (f + b1 + fm): up to 100 units 2.2-2.7 s; 101-500 units 2.7-5.3 s, against 5.3-8.3 s now; each 0.3 s less
  once the doubled wait is gone.

| File | Now | After (rough) | Goes |
|---|---|---|---|
| `FieldText.swift` | 671 | 300 | B2/R2/FE, `bh`, second look, rejudge, retries, the return's wait, Replace's gate and check, the statics |
| `WholeRead.swift` | 408 | 250 | `refusal`, `collapsed`, `shifted`, both `undone`, `resync`, `slowStep`, `quiet`, `replaceLimit` |
| `KeyboardViewController.swift` | +226 | +110 | `replacing`, `writeTask`, the writing strip, the unsure panel, Copy original, early-cancel plumbing |
| Tests and CI harness | +3056 | +1400 | tests of deleted rules; `long`, `r4k`, `s3`, `shead`, `etail`, the Lexical host, the race judge, the lat- gate |

Keep: `safeJump`, both step checks, `Speculative` (adopt iff equal, else cancel), `CursorReturn`, `FieldGuard`'s
window rules, `touchedSinceRead`, the refusal panel, `replaceSettle` as "no new read this soon after a write".

**Risks**
1. Evidence, not proof: a host that lags at a false start with no sign, and still lets R1 and FM look right,
   gives a partial read. Not seen in the replay (the 21 runs whose logs carry the flags). Today's window proof
   has the same exposure.
2. Web fields are mostly refused. If they matter on the phone, the price is the second pass for unclean reads only:
   about 250 lines and today's flakiness.
3. Replace without a check: a host that counts a delete differently from a Swift `Character` leaves old text in
   front, as on main today. Insert-at-once behind many deletes on a web page was last measured with a check walk
   behind it (run 172); run 1 must show it clean, else keep the wait before the insert.
4. The constants stay simulator numbers until the phone session.

**The tower's ideas**
- Cap of 3 s: right direction, wrong alone. With the second pass in, only the window proof fits in 3 s (the full
  proof of 39 units takes 4.4-5.6 s), so every draft the window does not show whole is refused: every case of
  the P1 report. After the cut, 335 units take 2.4-2.6 s with the cursor at the end and 4-5 s with it in the
  middle, so the cap is 5 or 6 s, set after the phone session.
- Detect web hosts by behavior: no. Nothing tells before the read; what tells during it is a misfit the rule
  already refuses on. Card before proof, gating only Replace: no. It adds a card whose text may be withdrawn and
  fixes neither Replace nor web; with the real API the one-pass read already hides behind the call.
- Drop whole-field Replace: Replace is not the cost (N deletes, as on main); its proof is. Trust a short context:
  nothing proves it short; a 149-unit draft showed 24 units (P1a table).

**Test plan, 2 CI runs**
- First, no CI: `swift test` for the acceptance rule, and the replay above on the rule's exact conditions.
- Run 1: one filtered run with both methods (`test5g_wholenative`, `test5h_wholeweb`) on the cut matrix (uikit,
  swiftui: win, mid, sel, swin, smid, ssel, emoji, x14k, cancel; textarea: win, swin, emoji). Pass: accepted reads
  exact by hash; refusals within the cap, cursor back; the field exact after Replace and after Undo by the UI
  test's own read; keys-wait under 100 ms; `read ms` at most 2500 on the short cases. A web case that fails is
  answered by refusing that case, not by a new rule.
- Run 2: the full `[shots]` run on that head against `d7d5010-136` and `cd570cf-194`.
- Then the test that counts: phone on USB, `idevicesyslog` on category `read`, ten Translates in the owner's real
  apps (five typed in one go, five after tapping back into a multi-line draft). That sets the constants.

## 5. Kill list

1. Stop the F02c loop: no more commits to `fix/whole-field-read`, no more `diag/k1b-*` runs.
2. Stop saying "proven". Say "accepted", and refuse on any sign of lag instead of waiting it out.
3. Stop proving Replace and Undo (the timer, the check walk, the notice), and stop the second pass.
4. Stop adding one rule per failed run, and stop coding against hosts no run has shown.
5. Stop the main + 500 ms gate against a 0.4 s stub. Gate the read's own time; record the rest.
6. Stop reading 4000-unit fields through a keyboard: cap by time.
7. Stop tuning on the simulator what only the phone can answer.
8. Stop flight briefs that say "fan out, run CI in parallel, do not wait for the owner" on a design question.
