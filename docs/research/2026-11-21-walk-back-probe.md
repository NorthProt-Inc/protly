# Walk-back probe (P1a follow-up for K1b)

> **STATUS: PARKED, NO RESULTS YET.** The probe is built and its first CI run was started, then left running when the
> laptop session stopped. Nothing below is a measured result on the simulator. Read "State when parked" first.

Branch `diag/p1-walk-back`, started from `origin/diag/p1-phone-read` (28771e2), not rebased on main: the CI build of
the diag base was enough, so no merge was needed. Never merged into main, no PR.

## Question

K1b wants `FieldText.read` to find both ends of a field by moving the cursor instead of trusting
`documentContextBeforeInput`. The forward walk was measured in the keyboard diagnosis (P1a). The backward walk was not.
This probe asks, on the CI simulator (iOS 26.5, Xcode 26.6):
- Does walking the cursor back read the whole field before the cursor, after a host resync (the window case)?
- Which step policy works: one-unit steps, or jumps of the current before-context length?
- Does a step back over a line feed or a blank line behave like the forward case?
- How is the start detected? Does a step back at the true start change nothing for 0.5 s, and is there any false start?
- After walking back and then forward again, is the cursor where it started (Replace depends on it)?
- With select all set in code, what does collapsing the selection to the start or the end do?
- How long does the walk take on the 3230-unit draft?

## Probe design

**Keyboard (`ios-app/Sources/ProtlyKeyboard/FieldText.swift`).** On this branch every read is `FieldText.walkRead`:
1. A selection is collapsed first with `adjustTextPosition` +1, -1 or 0, in turn across select-all calls
   (`selCalls`). If the selection is still there after -1 or 0, a +1 follows.
2. From that base: the **unit** walk back (one UTF-16 unit a step), then one move forward by everything walked
   (the return check), then a walk forward to the end.
3. From the end: the **jump** walk back (by the whole before-context), one move forward, a walk to the end again;
   then the same with **jump1** (by the before-context less one unit).
4. The read returns the first whole text found (unit plus forward, jump1, jump) with the cursor at the end.

Rules inside each walk:
- A step waits for any context to change, polling every 20 ms, up to 1 s (0.5 s for a probing step).
- Walking back, the piece moved over is the end of the before-context the step started from. A step from an empty
  before-context is a probe: no change for 0.5 s is the start; a change there is counted as a false start.
- A step that changes nothing although the before-context had text ends the walk as `stuck`.
- Walking forward, the step is the after-context less one unit, or one unit when it is empty (over a line feed). The
  end is a one-unit step that changes nothing for 0.5 s.
- The first unit walk longer than 1700 steps in the keyboard process may run to 6000 steps or 200 s. Later ones stop
  at 1700 steps, to keep the methods short.

Why the jump walks start from the end: a step that "changed nothing" may still have moved the cursor, so after a
stuck walk the cursor position is unknown. The end is the one place a forward walk always finds again.

**Logs (`keyboard-log.txt`, category `read`).** Lengths, line-feed counts, FNV-1a hashes and timings, never text:
- `walk start`, `walk collapse`, `walk base`, `walk whole`.
- `wb <policy> s=... k= polls= ms= late= front= cons= aok= lf= fs=`, per step:
  - jump steps: every one is logged;
  - unit steps: logged only when a check failed, polls > 2, a line feed was crossed, or every 100th step.
- `wb <policy> done ...`: units, line feeds, hash, reason, steps, time, a polls histogram, front growth and shrink
  counts, inconsistencies, false starts.
- `wr <policy>`: the return move: `r1` (both contexts as at the base), `rs` (the before-context is the end of the
  walked text), `rx` (neither).
- `wf <tag> ...`: the forward steps and their summary.

**Stub reply and UI test.** The CI stub answers every draft with
`read <utf16> <lf> <tokens> h<hash> | c..= u=<units>/<lf>/h<hash>/<reason>/<return>/<ms>ms f=... j=... fj=... j1=...
fj1=... pick= agree= ms=`. `ios-app/CI/UITests/WalkChecks.swift` hashes the host's text the same way (FNV-1a 32 over
UTF-16 units; `read-probe.html` posts the hash for the web fields) and writes one RECORD line per case:
- `whole=1`: the read returned the whole field (length, line feeds, hash).
- `u=pre/win/cur`: the unit walk text is the field's first n units / the n units before the cursor / n is the cursor.
- `f=suf`: the forward walk text is the field's last n units.
- `j=pre/all`, `j1=pre/all`: the jump walk text is the field's first n units / n is the field's length.
- `sel` and `selafter`: the UITextView selection before and after the call; `left`: the field after Cancel.

**Cases** (drafts from the P1a table, `HostApp.swift` `ReadDrafts`):

| Method | Host | Cases (tries) |
|---|---|---|
| `test5j_walkuikit` | UITextView | p5 318/8 end (2), l5 114/4 single line feeds (2), xlong 3230/14 end (2), p5mid cursor in paragraph 2 (2), l5mid (1), longmid 1518 (1), trail ending in a line feed (1), select all on p5 (3) and xlong (3) |
| `test5k_walkswiftui` | SwiftUI field | p5 (2), l5 (2), xlong (2); its fill leaves the cursor at the end, and it has no select all |
| `test5l_walkweb` | read-probe page: textarea, Lexical-shaped | p5 (2), xlong (1) each, after the page's fill, Dismiss and a tap at the field's end |

## Offline check (a model, not evidence)

Before the CI run, `walkRead` was compiled on Linux against small UIKit and os shims and run on a fake proxy. The fake
modeled a before-context of the last 3 sentences, an after-context up to the next line feed, and moves landing 8 ms
late.
- The whole field came back on p5, l5, p5mid, xlong and all three select-all collapses.
- The unit walk on xlong took 66 s at about 20 ms a step.
- In a second model the after-context was capped at 59 units. There, both jump policies stopped as `stuck` on the
  repeated sentences: two windows read the same text, so the move cannot be seen. The unit walk and the forward
  walk still read the whole field.

This only shows that the probe's logic and the judge's parsing are consistent. **Guess:** the repeated sentences of
the P1a drafts may make the jump policies stop early on the simulator too. The 302-unit `notApplied` exception in
P1a cause 2 fits that guess.

## Results

None yet. See below.

## State when parked

- **Pending run:** GitHub Actions run `44978016768` (run number 135), workflow `keyboard-shots`, head `7f2f443`, filter
  `test0_access`, `test5j_walkuikit`, `test5k_walkswiftui`, `test5l_walkweb`. It was still in the build-and-test step
  at 03:15 UTC on 2026-11-22, about 23 minutes after it started. That long a run means the build very likely passed.
  Its folder will be `runs/7f2f443-135` on `ci-shots`. Tries used: 1 of 3.
- **Read it:** `git fetch origin ci-shots`, then `git show origin/ci-shots:runs/7f2f443-135/report.txt`, `checks.txt`,
  `keyboard-log.txt` and `test-cases.txt`. `2026-11-21-walk-back-analyze.py <folder>` (next to this file, not yet
  tried on a real run folder, so its patterns may need a fix) prints:
  - per try: the verdict and the walk numbers;
  - every walk summary, start/stuck/end line and return line from the keyboard log;
  - a histogram of unit steps by line feed, polls and checks, and the jump steps.
- **Analysis left:**
  - For each case, per policy: reached the start or not, false starts, stuck steps.
  - Poll latency per step, and new units at the front of the before-context.
  - Unit steps over a line feed or a blank line, compared with the forward case (one-unit step, seen at the first poll).
  - The start probe: nothing changed for 0.5 s at the true start.
  - Return codes (`r1`/`rs`/`rx`) and `selafter` (cursor at the end after the read).
  - Select all: the effect of +1, -1 and 0 on `sel`, `before` and `after`.
  - Total walk times on xlong: the unit walk once in full (the first long one), the jump walks every time.
  - The web hosts: does walking back show more than the last 2 sentences?
  - Then write the Results section and the recommended K1b read algorithm, and mark each claim confirmed or guess.
- **If the run fails:**
  - **`build-failed`:** fix the compile error (report.txt ends with the log tail). The new code is in `FieldText.swift`
    (walk section), `StubActionClient.swift` (the reply line), `WalkChecks.swift` and `PhoneChecksUITests.swift`.
    Push with the same filter tag.
  - **`test-failed` on a method's time limit (1500 / 1200 / 1200 s):**
    - Cut tries first: xlong and selxlong to 1, the web xlong cases out.
    - Or lower `unitShortCap` (1700) in FieldText.swift to about 600.
    - The test waits up to 300 s for each card.
  - **Every jump walk `stuck` on the repeated-sentence drafts:** that is a finding, not a failure. If the unit walk is
    stuck too, add a draft with unique sentences: `ReadDrafts.sentence` with a per-sentence number. Keep the P1a
    drafts beside it.
  - **Cards that never come (`outcome=timeout`):** check `keyboard-log.txt` for the last `wb`/`wf` line. A step limit
    or cap may need lowering, or the tree polling (every 1.5 s) may slow the steps; see `polls` > 2 counts.
- **Uncommitted work:** none. The simulation shims (`shims.swift`, `fake.swift`, `main.swift`) stayed in the laptop
  session's scratchpad and are not needed for the analysis.
