# K1b design: the keyboard reads the whole field

Base: main 521e318. Port of the strict walk read (`diag/p1-walk-back-strict` 471e282, probe only) as clean code.

## 1. Pure parts (ProtlyCore, new file `WholeRead.swift`, tests first)

- `WholeRead.safeJump(_ units: [UInt16], back: Bool) -> Int`: the largest k < n that is not a period of `units`
  and does not land the cursor before a low surrogate; 1 (2 when 1 splits a pair) below that. As in the probe.
- `WholeRead.fnv(_ units:) -> String`: FNV-1a 32 over UTF-16, 8 hex digits (logs, CI stub, UI tests).
- `BackWalk` (value type, one walk back):
  - `mutating plan(before:) -> Int`: k to move back (safeJump, or 1 when the before-context is empty = a probe).
  - `mutating landed(changed:before:after:) -> Step`:
    - `.moved(delta)`: the step fits (the new before-context ends with what the old one kept, the new
      after-context starts with the piece up to its first line feed); the piece is kept.
    - `.start`: a probe that changed nothing (the driver waits 0.5 s for that).
    - `.phantom`: a probe that changed something but left the before-context empty: skipped, no text.
    - `.bad`: a probe that found text (a false start: the unit would be a guess), or a step that fits nothing.
    - `.characters`: a step that fits k + the surrogate pairs crossed, not k (the web moving by characters, text
      with emoji). Refused, never corrected (owner decision; probe runs 150, 153).
    - `.stuck`: a non-probe step that changed nothing.
    - `.capped`: the walk read more than `cap` units (4000; the second walk: more than the first walk's length).
  - `units`, `count`, `lineFeeds`.
- `ForwardWalk` (to the end): `plan(after:)` = safeJump(after, back: false), or 1 when the after-context is empty
  (a probe over a line feed); `landed(...) -> .moved(delta) | .end | .stuck | .bad | .capped` (bad: the new
  before-context does not end with the piece; capped: more than 4000 units walked = the field is too long).
- `WholeRead.accept(first:, mid:, back1:, back2:, last:) -> Refusal?`: nil only when the first forward walk and the
  mid and last confirmations found the end, both walks back reached the start, read the same units, and no step was
  bad. The last walk may move a few units (a return landing short; probe looser rule, not run in CI before K1b).
- `WholeRead.Refusal`: `tooLong`, `timeUp`, `noEnd`, `noStart`, `badStep`, `characters`, `disagree`, `cancelled`
  for logs; one panel text for all of them (section 5).
- `WholeReadBudget` (replaces `FieldReadBudget`, which is deleted): total 20 s; `showsProgress(now:)` after 2 s;
  `canStart(stepWait:now:)` = the step's longest wait still ends within 20 s (the cap stops a read only between
  steps); step waits: 1 s for a move to show, 0.5 s for a probe, 0.3 s for an empty before-context to come back;
  settle = poll every 20 ms until two polls agree (at most 5 more).
- `CursorReturn` (rewritten, same role): the signed UTF-16 offset of the cursor from where the user had it, while
  known. `sending(delta)`, `applied(checked:before:)` (an unchecked step makes the position unknown),
  `notApplied()`, `reachedEnd(before:)` (the first end found with a known position sets `endOffset`; a later end
  makes an unknown position known again), `back(before:) -> Int` = the move that puts the cursor back, 0 when
  unknown or when the before-context no longer agrees at its end with the one after the last step (typed or moved
  since). The Retry continuation is cut: a refused read puts the cursor back at once, a Retry reads from scratch.
- `FieldGuard.canReplace` for a whole read: after-context empty, before-context non-empty and the read text ends with
  it (the before-context is a window of at most about 300 units, so the old `before.hasSuffix(original)` refused
  every read longer than the window). `canUndo` the same way for the inserted text. New
  `FieldGuard.holdsResult(result, before:, after:)` for the check after Replace (the same rule).

## 2. Proxy driver (`FieldText.swift`, async, @MainActor)

`read(proxy, record:, progress:) async -> Outcome` with `Outcome = .text(String, isSelection) | .empty |
.refused(Refusal) | .cancelled`:
1. Partial selection (selectedText non-empty and at least one context non-empty): K1a, unchanged: returned as the
   selection, the card only copies. Select all (selectedText non-empty, both contexts empty: run 153 logs show
   `before=nil after=nil sel=43/0` for every select all): one +1 step collapses it to the end, then the whole read.
   The user's selection is not restored by Cancel (only the cursor, at the end).
2. Nothing selected and both contexts empty: `.empty` at once (as today; the protly key reads the clipboard).
3. F: forward walk to the end. B1: walk back to the start. R1: one move forward by B1's length. FM: forward walk to
   the end. B2: walk back. R2: +B2's length. FE: forward walk to the end. Every step settles; before every step:
   `Task.isCancelled` -> `.cancelled`, budget -> `.timeUp`. A refusal ends the read at once (no later walk), except
   that an unknown cursor position with a known end offset runs one forward walk to the end first, so the cursor
   can go back.
4. Accept (WholeRead.accept) -> `.text(B1's text)`, cursor at the end. Whitespace only -> `.empty`.
5. Logs (`Logger` category `read`): per walk its units, line feeds, hash, reason, steps and ms; per read the outcome
   and ms. Never text.

## 3. Budget, progress, Cancel

- Keys wait for the whole read (as today, `readingCall`), at most 20 s.
- Progress: after 2 s the strip's second line says "Reading the whole text…" (`StripState.readingLong`, set once).
- Cancel (strip xmark, hide): as today. A step on its way settles first (`restoreWhenReadEnds`), then the cursor goes
  back by `CursorReturn.back` in one move.

## 4. Replace, Undo

- Replace: the cursor is at the end of the whole read: `deleteBackward` once per Character of the read, then
  `insertText`. Then a check task polls the contexts every 50 ms for up to 5 s until `holdsResult`; it logs the
  delete count, the time to send and the time until the field held the result. A failed check shows the notice
  "Replace may not have finished. Check the text." (Undo stays offered). Typing or a cursor move cancels the check.
  CI measures 3230- and 3958-unit Replace; if it is slow, a faster path is looked for then (none known: the proxy has
  no range delete).
- Undo: deletes the inserted result (one call per Character) and inserts the whole read text (`lastInsert.original`
  is the read).

## 5. Refusal

Any refusal: `.failed("Could not read the whole text. Copy it, then use Read clipboard.", retry:)` and the cursor
back where it was (when known). No "Select all" advice anywhere.

## 6. CI checks (method `test5g_wholeread`, filtered only like test5f_period: about 25 cases of up to 20 s would
push a full run past the 65 min deadline)

- IDs `wr-<host>-<case>`; hosts `uikit`, `swiftui`, `textarea`, `lexical`; cases `win` (318 units, cursor at the
  end after a resync), `mid` (cursor in paragraph 2), `sel` (select all), `long` (3230), `x14k` (14 038, expects the
  refusal), `emoji` (web hosts only, expects the refusal); plus `wr-uikit-r4k` (3958 units: Replace and Undo time).
- Drafts start with `protly-stub read` so the CI stub answers `read <utf16>/<lf>/h<fnv> t<read ms>`; PASS when that
  shape equals the host's draft, the field after Replace equals the card text exactly, Undo puts the draft back
  exactly, and the cursor is at the end after the read. Refusal cases: PASS when the panel text is the refusal text
  and the field is unchanged after Cancel.
- checks.py / test_checks.py learn the IDs (METHOD_IDS, FILTERED_ONLY).

## Cut

The probe's unit and jump policies, the +1 000 000 move, the characters correction, the Retry continuation, the
2 s FieldReadBudget, all probe logging of contexts.
