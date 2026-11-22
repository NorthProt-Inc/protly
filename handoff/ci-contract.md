# K1b CI contract (keyboard side <-> UI tests)

Fixed by the tower (main session). The keyboard side is written by the tower; the UI tests by the CI agent.

## Stub
- A draft (the whole field text the request carries) that starts with `protly-stub read` (StubActionClient.marker +
  `read`) gets the CI stub's reply as the translation: `read <utf16>/<lf>/h<fnv> t<ms>`
  - `<utf16>`: UTF-16 length of the whole text the request carried, `<lf>`: its line-feed (U+000A) count,
    `<fnv>`: FNV-1a 32 over its UTF-16 units, 8 lowercase hex digits (offset 0x811C9DC5, prime 0x01000193, xor then
    multiply, per unit; ProtlyCore `WholeRead.fnv`), `<ms>`: how long the keyboard's field read took (integer ms).
  - back translation: `ok`. The card opens with Replace (Translate) once done, about 0.5 s after the read.
- Example: `read 335/9/h6d75860b t4210`.

## Panel and strip texts
- Refusal (any read that cannot be proven whole): panel (`protly-panel`) text exactly
  `Could not read the whole text. Copy it, then use Read clipboard.` with buttons `Cancel` and `Retry`.
- After 2 s of reading the strip (`protly-strip`) shows a second line `Reading the whole text…` (U+2026).
- Replace on the card (`protly-card`); after it the protly key is Undo (tap the protly key to undo).
- A check after Replace that fails shows a notice panel `Replace may not have finished. Check the text.` (Done).

## Keyboard behaviour the checks rely on
- Select all (before- and after-context both empty, selectedText non-empty): collapsed to the end, then the whole
  field is read; the card can Replace. A partial selection: K1a, copy-only card (no Replace).
- After an accepted read the cursor is at the end of the field. After a refusal the cursor is back where it was
  before the tap (when the keyboard knows where that is) and the field is unchanged. Cancel on the card puts the
  cursor back where it was before the tap.
- Reads take 3-16 s on native hosts; the hard cap is 20 s; then the stub's call about 0.5 s.

## Keyboard log (keyboard-log.txt, category `read`), numbers only
- `read done outcome=<accepted|refused|empty|cancelled> reason=<-|tooLong|timeUp|noEnd|noStart|badStep|characters|disagree> units=<n> lf=<n> h=<fnv> ms=<n> steps=<n>`
- `read walk <f|b1|fm|b2|fe> units=<n> reason=<...> steps=<n> ms=<n>`
- `replace deleted=<n> inserted=<n> sentms=<n> heldms=<n> held=<0|1>`

## Changes after the design review
- Replace now: all deletes, then the keyboard waits (keys wait too) until the field is empty, then inserts, then
  checks. If the field never empties within 5 s it still inserts, shows the notice
  `Replace may not have finished. Check the text.` and offers no Undo.
- A key tap or a cursor move by the user between the read and Replace makes the card copy-only
  (`The text changed while this ran. Copy the result instead.`): the UI test must not touch the field between the
  protly key tap and Replace.
- Empty field: about 1.3 s of probes before the clipboard is read.
- `replace` log line: `replace deleted=<n> inserted=<n> sentms=<n> emptyms=<n> empty=<0|1> heldms=<n> held=<0|1>`
