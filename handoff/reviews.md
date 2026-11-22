# F02 reviews of a6de577 (both reported before the handoff)

Status per finding: DONE = in the handoff commit (working tree, not yet CI-tested), OPEN = not done.

## Design review (code-architect, before code): NEEDS CHANGES; all 10 adopted in a6de577 (bad steps record the
requested move instead of "unknown"; forward probe must show a line feed; Replace waits for an empty field; touched flag)

## silent-failure-hunter: Not ready
1. Repeated false start accepted (F's units never compared with B1). DONE: WholeRead.refusal(first:) -> "firstEnd".
2. Check after Replace sees only the window. DONE: FieldText.holds walks back over the result (cap = its length),
   must read exactly it, then one move to the end; Undo only when emptied && held.
3. Undo had no safeguards. DONE: Undo of a Replace runs FieldText.replace the other way, keys wait.
4. Hold check 2 s, not 5. DONE: FieldText.writeWait = 5.
5. Cursor not put back after some refusals (phantom, short return). PARTLY: logged (`read restore ... known=0`);
   the forward walk to re-anchor is OPEN.
6. SwiftUI mid/sel unprobed. DONE by the CI agent (SelectingField sel probe; uses TextSelection.indices, NOT
   compiled yet).
7. Any refusal passes a refusal case; web caret after Cancel not checked. Web caret DONE (CI agent). Checking the
   refusal reason (tooLong for x14k, characters/badStep for emoji) is OPEN: the tower meant to read it from
   keyboard-log.txt `read done ... reason=` by hand.
8. `.cancelled` grouped with `.empty`. DONE: own case, never reads the clipboard.

## code-reviewer: request changes
1. same as SFH 1. DONE.
2. Cancel during the empty-before wait (not isMoving) lets restoreCursor run, then the walk sends one more step;
   the select-all collapse step is not recorded. OPEN. Fix: `if Task.isCancelled { return end(.cancelled) }` after
   the wait loop; record(.sending)/.landed around the collapse.
3. Insert after waitEmpty failed glues the result to leftovers; waitEmpty returns false on the first moved probe.
   OPEN. Fix: when !emptied do not insert (card copy-only + notice, or put original back); in waitEmpty undo the
   probe and `continue`.
4. Same as SFH 5. OPEN.
5. Same as SFH 3. DONE.
6. `action` used in `case .refused` before the later `let action` in the same closure: rename the later one to
   `draftAction`. OPEN (possible compile error on macOS).
7. Same as SFH 4. DONE.
8. canUndo has no after.isEmpty check for whole-field inserts. OPEN.
