# Walk-back probe (P1a follow-up for K1b)

> **STATUS: MEASURED (11 CI runs, 2026-11-22). Verdict: partly.** Walking back works on native fields (UITextView,
> SwiftUI) up to about 4000 UTF-16 units with the strict read (runs 154 and 155: 48 of 58 reads kept, all exact, the
> 2 wrong ones rejected), and on web fields without emoji. Web fields with emoji (the host moves by characters) and 14 000-unit fields were not read exactly; the strict
> read refuses them instead of returning a wrong text. See "Answers" and "Recommended K1b read".

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


The guess was right: run 7f2f443-135 confirmed it (below), and the drafts with unique sentences (1233d72-139) removed
every `stuck`.

## Results

All runs: workflow `keyboard-shots`, iOS 26.5 simulator, Xcode 26.6, filter `test0_access`, `test5j_walkuikit`,
`test5k_walkswiftui`, `test5l_walkweb`. Folders are `runs/<sha7>-<run>` on `ci-shots`. Every number is from that
folder's `keyboard-log.txt` (category `read`: `walk whole`, `wb <policy> done`, `wf <tag> done`, `wr` lines) or the
`CHECK walk-*` RECORD lines of `checks.txt`, put side by side by `2026-11-21-walk-back-analyze.py <folder>` (next to
this file; it maps each keyboard read to its try by the MARK times in `ui-log.txt`). "Exact" = length, line feeds and
FNV-1a hash equal the field's (`real=` in the RECORD). Drafts and hashes for the default drafts were also rebuilt
offline from `HostApp.swift` `ReadDrafts` (p5 318/8/h6d75860b, l5 114/4/h377e638b, xlong 3230/14/h7328b445, longmid
1518/8/hc63d54cb, trail 71/5/hb9b91f66 all equal the RECORD values), which identifies several walked texts below.

### Runs

| Run folder | Branch @ head | Question | Answer | Status |
|---|---|---|---|---|
| `7f2f443-135` | `diag/p1-walk-back` @ 7f2f443 | unit, jump and jump1 walks on the P1a drafts | jumps exact wherever they reached the start; stuck on repeated sentences; unit walks: right length, wrong text | passed (RECORD unparsed, fixed in cae21c5) |
| `f3f2623-140` | `-unit` @ f3f2623 | does settling every unit step make the unit walk exact? | no: 2 of 18 native/textarea unit walks still wrong; 56.6-82.0 ms a step | passed |
| `1233d72-139` | `-unique` @ 1233d72 | unique sentences: do the plain jump walks reach the start of the long draft? | yes, 3958 units exact in 4.6-8.0 s a walk | passed |
| `3293a10-138` | `-np` @ 3293a10 | the np step (never a period of the context) on the repeated drafts | 28 of 29 walks back exact, 3230 units in 5.4-6.7 s; forward walks about 4x slower | passed |
| `71f21ff-146` | `-k1b` @ 71f21ff | a +1 000 000 move to the end; two np walks back compared | big move unreliable; 25 of 29 reads kept, all exact; every wrong read rejected; 3230 units 14.0-15.1 s a read (native) | passed |
| `3182f20-145` | `-mix` @ 3182f20 | np read on Korean + English + emoji drafts, xlong 14 038 units | breaks: web 433 of 443 and 13 718 of 14 038 (one unit per emoji), native 14 038 texts wrong | passed |
| `340f403-149` | `-safe` @ 340f403 | never land inside a surrogate pair; two np walks back | native up to 2173 units: 16 of 16 exact; web still 433 (and one such read kept: a wrong accept) | passed |
| `4a2110a-150` | `-units` @ 4a2110a | does the web move by characters? fit the move from the contexts | yes: m - k = pairs crossed in 674 of 827 adjusted steps; web 439 of 443 | test-failed (test5j: "Failed to get screenshot", after 4 tries) |
| `57c5539-154` | `-strictlong` @ 57c5539 | the strict read on the default drafts (3230 repeated units) | 58 of 58 walks exact; 26 of 29 kept, all exact; 3 exact Lexical reads rejected; native 3230 in 12.5-15.4 s | passed |
| `abe62c8-155` | `-strictlong-unique` @ abe62c8 | the strict read on the unique Korean drafts (3958 units) | 55 of 58 walks exact; 22 of 29 kept, all exact; 2 wrong reads rejected, 5 exact ones too; native 3958 in 10.8-14.1 s | passed |
| `471e282-153` | `-strict` @ 471e282 | wait out empty before-contexts, distrust unfit steps; keep only clean agreeing walks | no wrong read kept (14 kept, all exact); every web and 14 038-unit read rejected | passed |

### Run 7f2f443-135 (the parked run)

The RECORD lines all say `carried="→"` and `whole=unparsed`: the stub's reply is long, wraps above the card's `→`
row, and `CallView.cardRows` took it for the header (fix: WalkChecks.swift searches every card text for `read `,
commit cae21c5; runs 139 on show the parsed judge). The analysis below uses the keyboard log.

- **29 reads** (29 `walk start`/`walk whole` lines, one per try: uikit 17, swiftui 6, web 6).
- **Whole field returned: 11 of 29**: 7 x 318/8/h6d75860b, 4 x 114/4/h377e638b (uikit p5 t2, l5 t1, p5mid t1-t2, l5mid,
  selp5 t1; swiftui p5 t1-t2, l5 t1-t2; textarea p5 t1).
- **Per policy** (analyzer totals): jump and jump1 each reached the start in 21 of 29 walks and were exact in 17;
  the 8 `stuck` are all on the repeated-sentence drafts (uikit xlong x2, longmid, selxlong x3, swiftui xlong x2). The
  4 that reached the start but are not exact: textarea xlong (jump 82 = the field's first 82 units, jump1 102 = first
  102, both from where the forward walk got stuck) and lexical p5 x2, xlong (a phantom line feed, below). The probe
  picked the unit walk first, which is why only 11 returned whole.
- **`agree=0`: 7 reads** (log lines 61, 194, 773, 897, 951, 1666, 1712). 6 are a wrong unit walk next to exact jump
  and jump1 walks (uikit p5 t1, l5 t2, trail, selp5 t2, t3, textarea p5 t2). 1 is textarea xlong (jump 82 vs jump1
  102, both exact prefixes). Two more reads are wrong with `agree=1` because only the unit walk counted (uikit xlong
  t1 3230/14/hf1838e64, longmid 1518/8/h794f0245).
- **Cause of the wrong unit walks: a stitching error, not repeated sentences.** Every unit walk with `incons=0` (12)
  is exact against the text it covers; every one with `incons>0` (17) is wrong. Lengths and line feeds stay right
  (one unit per step, the start found at the right count), the units are wrong: the walk read a context that did
  not belong to the cursor's position (bursts of `cons=0` with `front` jumping, e.g. +4 then -4). Unit steps took
  no settle poll. Run 140 settled every unit step (two equal polls): still 3 walks with `incons>0`, 2 of them wrong
  (uikit p5 t2 318/8/h6006b4e3, swiftui p5 t1 318/8/h8458b943), at 56.6-82.0 ms a step instead of 28-61
  (`wb unit done` ms / steps). The jump
  steps (one settle poll) had `incons=0` in all 252 logged steps of run 135 and all of runs 139 and 140.
- **Repeated sentences explain the jump `stuck`**: the drafts repeat one 19-unit sentence plus a space (period 20).
  On xlong a jump of 60 (3 periods) and jump1's second step of 40 (2 periods) gave the same before- and after-context,
  so "nothing changed" for 1 s (e.g. `wb jump stuck s=2 k=60 polls=46 ms=1003 before=60/0 after=20/0`).
- **What stops the 3230-unit draft**: the probe's own cap. The unit walk ended `step-cap` at 1700 steps
  (`unitShortCap`) in 6 reads, after 47.6-72.9 s (`wb unit done 1700/8/... step-cap steps=1700`); the one uncapped
  walk (uikit xlong t1) reached the start after 3231 steps and 117.9 s, with the right length and a wrong text
  (`incons=16`). The jumps stopped after 2 steps (1.05-1.10 s), once after 3 (uikit xlong t2 jump: 119 units,
  1154 ms), on the repeated sentences. No host limit and no time
  budget stopped anything. Faster: np walks (run 138) read the same draft in 5.4-6.7 s.
- **Web lengths 102, 321, 64 are not the "only what the keyboard typed" limit**: the walks read text the keyboard
  never typed. textarea p5: jump and jump1 exact, 318 in both tries. textarea xlong 102 = jump1's exact first 102
  units, from a forward walk stuck on the repeated sentences (`wf f ... stuck steps=2`). lexical p5 321/9 = unit
  62/1 + forward 259/8 (the walks back there were 319/9/h7550aba3 = a line feed + the exact field). lexical xlong
  64/1 = unit 61/1 + forward 3 (stuck). Both xlong web tries ended on the cut-short panel because the cursor was not
  at the end (`after=21/0`).
- **The phantom line feed (Lexical-shaped field)**: at the true start (`before=nil after=23/0`) a -1 step changed the
  after-context to nil without crossing text; the probe counted that as a line feed. The next probe changed nothing
  for 0.5 s (`start`). Skipping such a step (np branch) gave the exact 318/8/h6d75860b on lexical p5 (run 138).
- **Select all: 6 tries** (selp5 x3, selxlong x3). Whole by the probe's pick: 1 (selp5 t1, `pick=jump1`). By the
  jump walks: 3 of 3 selp5 exact, 0 of 3 selxlong (stuck). While selected, `selectedText` was 43/0 (a window, not
  the 318 or 3230 selected). Collapse: +1 lands at the end (`walk collapse v=1 ch=1 ... after=nil`); -1 lands one
  unit before the end (`before=61/0 after=1/0`; the unit walk then read 317); 0 changes nothing for 1 s, then +1
  lands at the end. None collapses to the selection's start.
- **Start detection**: in native hosts every walk that reached the start ended with a -1 probe at an empty
  before-context that changed nothing for 0.5 s (`wb <policy> start s=.. polls=2x ms=5xx before=nil`); no false
  start in run 135's native walks. Empty before-contexts mid-field did appear later (runs 139, 145, 149, below).
- **Line feeds**: 149 unit steps over a line feed were logged (`wb unit s=... lf=1`). 144 were seen at the first
  poll with consistent contexts (`polls=1 cons=1 aok=1`), as in the forward case; 2 were seen at the first poll with
  `cons=0`; 3 were start probes (`fs=1`, the Lexical phantom) that needed 3-7 polls.
- **Return** (`wr`): `r1` after every jump walk that reached the start in native hosts; `rx` after lexical walks
  (the phantom step); `rs`/`rx` after stuck jumps.
- **Cursor after the read**: `selafter` at the field's end in all 17 uikit tries; `left=` equal to `real=` in all 29
  (Cancel left the field as it was).

### Run 1233d72-139: unique sentences, plain jumps

`-uniquedrafts 1` numbers every sentence (`3-12 `). Jump and jump1 each reached the start in 29 of 29 walks and were
exact in 26; the 3 others are Lexical with the phantom line feed (379/9/hdedb3e91 = a line feed + the exact 378-unit
p5, 3959/15/h74ec06c5 = a line feed + the exact 3958-unit xlong). xlong 3958 units: 81-86 steps, 4.6-6.5 s a walk in
native hosts, 6.8-8.0 s in the web fields (115-129 steps). One card had no reply ("The text changed while this ran.",
selxlong t3); the keyboard log of that read is exact. Native walks had false starts (an empty before-context
mid-field, `falsestarts` up to 3) and were still exact.

### Run 3293a10-138: the np step

np steps back by the largest k below the before-context's length that is not a period of it, so the move must
change the context (`FieldText.safeJump`). Read: forward to the end, np back to the start, forward again; kept when
both whole walks agree. On the default (repeated) drafts:
- np walks back: 29 of 29 reached the start, 28 exact. The wrong one (uikit p5 t1, 318/7) followed an empty
  before-context mid-field (`before=2/0`, then `nil`, then a false start), and was rejected (`agree=0`).
- Kept: 24 reads, all exact. Rejected: 5, the wrong one and 4 exact web reads whose second forward walk failed
  (textarea xlong: `wf fa ... bad=2`; lexical: from the phantom position the forward walk stopped at once).
- Time on 3230 units: np back 5.4-6.7 s (82-83 steps); the forward walk 335-337 steps, 20.3-23.3 s, because the
  after-context is short; the whole read 26.7-29.8 s.

### Run 71f21ff-146: one big move, two walks back

- `adjustTextPosition(+1 000 000)`: changed nothing when the cursor was already at the end (as expected), but also
  changed nothing at p5mid t1 (`after=12/0` stayed), moved part way at longmid (`after=12/0` after it), and in the
  textarea the forward walk after it stopped at a false end 39 units in. Not a way to the end; the forward walk is.
- Two np walks back from the end, each followed by one move forward by what it read (`wr npN ... r1`) and a forward
  walk that confirms the end: 58 walks, 56 exact. Kept 25 of 29 reads, all exact. Rejected 4: textarea p5 t1 (the
  false end: walks of 39 and 318 disagree) and the 3 lexical reads (returns `rx` after the phantom step).
- Time on 3230 units: native 14.0-15.1 s a read, of which 1 s was the useless big move and 2 x 5-6 s the walks
  back; longmid 1518 15.5 s (115 forward steps first); web textarea and lexical xlong 37.7-39.0 s (323-324 forward
  steps first). Short two-walk reads (71-318 units): 4.2-7.9 s.

### Run 3182f20-145: Korean + English + emoji

Drafts: numbered sentences taking turns: the Korean one, `Send me the notes after the call 👍.`, a Korean one with
🙂; xlong 8 x 60 sentences = 14 038 units (rebuilt offline: p5 443/8/h442c6280 with 10 emoji, l5 143/4/h73806425 with 3,
xlong 14 038/14/hef7a2fcb with 320). Read as in run 138.
- Native up to 2173 units: 15 of 16 exact; uikit l5 t2 read 142 of 143 (a jump of 51 from 52 moved to the start).
- Web: every p5 walk 433 of 443 and the xlong walks 13 718 of 14 038 (320 emoji): one unit lost per emoji.
- 14 038 units: 7 reads, every walk back wrong (right length or 1 short), `incons` 3-34, `falsestarts` 5-37 per walk,
  19.1-29.0 s per walk back. The second forward walk then failed: 4 of 7 hit the 800-step cap (selxlong x3, swiftui
  xlong t1), uikit xlong t1 and t2 hit the 60 s time cap (781 and 757 steps), and swiftui xlong t2 stopped at a false
  end 8772 units in (`wf fa done 8772/8/... end`; that try got a card, `whole=0`). Reads took 69-92 s; 6 ended on the
  cut-short panel.

### Run 340f403-149: surrogate-safe k

safeJump also refuses a k that lands the cursor before a low surrogate. Two np walks back as in 146 (no big move).
- Native up to 2173 units: 16 of 16 kept, all exact (uikit p5, l5, p5mid, l5mid, longmid 2173, trail, selp5 x3,
  swiftui p5, l5).
- Web: still 433/8/h627e53ea for p5 in textarea and lexical. textarea p5 t1 was **kept although wrong**: both walks
  lost the same 10 units, so comparing two walks does not catch it.
- 14 038 units native: 7 reads, all rejected (the two walks disagree); false starts 2-53 a walk (9-53 in the walks
  that read 14 038 units); 21-33 s a walk back. Two walks ended early at a false start: uikit xlong t1 walk 1 at 279
  units, swiftui xlong t1 walk 2 at 5963. Returns: uikit xlong t1 `rx,r1`, swiftui xlong t1 `rx,rs`.

### Run 4a2110a-150: the web moves by characters

When a step's contexts do not fit a move of k, the walk tried k plus the surrogate pairs crossed, then k +- 1..8.
827 adjusted steps: 674 fit exactly k + pairs (one more unit per emoji crossed; 663 of them in web walks, 11 in
swiftui xlong walks), 153 fit nothing (147 with 2 pairs crossed, 6 with none). The +-d search never chose a value. So
the web host moves `byCharacterOffset` in characters (here a single-scalar emoji counts 1). The 11 native k + pairs
fits made the swiftui xlong walks 3-5 units too long (14 043, 14 041), and their second walks ended early at a false
start (7873, 7962 units). Web p5 then read 439 of 443. test5j failed after 141 s on an XCUITest "Failed to get screenshot" (an
infrastructure timeout, not the probe), so uikit has only 2 tries.

### Run 471e282-153: strict walks

An empty before-context is waited out for up to 0.3 s before a probe step; a step whose contexts do not fit k is
taken as k + the pairs crossed only when that fits, else counted bad; a read is kept only when both walks reached the
start, agree, and had no bad step.
- **Kept 14 of 29, all exact** (uikit p5 t2, l5 x2, p5mid x2, l5mid, trail, selp5 x3; swiftui p5 x2, l5 x2). No
  wrong read was kept (run 149 kept one).
- Rejected: uikit p5 t1 (walk 1 exact; walk 2 read 444/8 with one bad step, so the walks disagree), longmid (2176
  of 2173), all 7 native 14 038-unit reads, all 6 web reads. The keep rule does not look at the returns: uikit l5 t2
  was kept with returns `rx,r1` (exact); 3 native reads up to 2173 units had an `rx` return (p5 t1, l5 t2, longmid),
  all 7 long reads `rx,rx`.
- Web p5: 439 of 443 in every textarea walk and in Lexical's first walks (the characters correction fixed 6 of the
  10 lost units; 2 steps a walk fit nothing and were counted bad, so the reads were rejected). Lexical's second walks
  read 0 units (they started at the phantom position).
- Native 14 038 units: in the first walks the empty before-context came back within 0.3 s 41-70 times (`waited`),
  35-61 steps were bad, the k + pairs fit was taken 78-121 times, and the walks came out 78-121 units too long
  (14 116-14 159). Every second walk ended at a false start 3757-4659 units in (k + pairs taken 20-37 times); only
  the disagreement of the two walks caught it. (The 223 and 224 k + pairs counts are the web xlong walks.) Run 149
  shows native hosts move in UTF-16 units on short fields; in long ones the contexts seem to lag the cursor (a
  guess), so the correction must not run on native hosts.
- Walks that ended early at a false start, over runs 149, 150 and 153: 11 (149: 279, 5963; 150: 7873, 7962; 153:
  the 7 native second walks). None was kept: each disagreed with the other walk.
- Time: native short drafts 3.8-6.6 s a read (two walks plus the end checks); 14 038 units 101-105 s a read.

### Runs 57c5539-154 and abe62c8-155: the strict read at 3000-4000 units

The strict read of 471e282 unchanged, on drafts without emoji: 154 on the default drafts (no `-uniquedrafts`: p5 318,
l5 114, longmid 1518, xlong 3230 of repeated sentences), 155 on the unique Korean drafts of run 139 (p5 378, l5 134,
longmid 1848, xlong 3958; `HostApp.swift` back to `sentence` only and 20 sentences a paragraph). Numbers from the
`walk whole` lines (`pick`, `ms`, `steps`, `ret`) and the stub replies (`bad=`, `fm=`, `fe=`) in `checks.txt`.
- **154**: 58 of 58 walks exact. Kept 26 of 29, all exact. Rejected 3, all exact: the Lexical reads (p5 x2, xlong),
  whose returns land 2 units short after the phantom step (`fm=2/end fe=2/end`), which the keep rule (`fe` must walk
  0 units) refuses.
- **155**: 55 of 58 walks exact. Kept 22 of 29, all exact. Rejected 7: 2 wrong (uikit selxlong t1, t2: a bad step in
  walk 1, `bad=1+1` and `bad=1+0`, the walks disagree) and 5 exact (the 3 Lexical reads as in 154; selp5 t1 and t3,
  whose second return landed 1 short, `fe=1/end`).
- Together: 48 of 58 reads kept, all exact; no wrong read kept; 8 exact reads refused. Native reads at 3230-3958
  units: 12 of 14 kept, all exact, the other 2 the wrong ones.
- **Time of a whole read** (two walks, the end checks, the forward walk first): native, cursor at the end: 3230 units
  12.5-15.4 s (uikit xlong 12.5-12.7, selxlong 13.5-15.4, swiftui 13.1), 3958 units 10.8-14.1 s, 71-378 units 3.6-4.9
  s; cursor in the middle: p5mid 5.5-6.2 s, longmid 1518 15.4 s and 1848 12.5 s (113-114 forward steps first). Web:
  p5 6.0-7.7 s, xlong 3230 28.7-31.3 s and 3958 44.2-46.6 s, because the tap put the cursor 60 units in and the
  forward walk to the end took 323 steps (15.9-23.1 s).
- A looser keep rule (both walks reached the start, agree, no bad step; `fe` may walk to the end) would have kept the 8
  exact refused reads and none of the wrong ones in 153, 154 and 155 (every wrong read there had `bad>0`). This is
  worked out from the logged fields, not run.

## Answers

- **Does walking back read the whole field before the cursor?** Yes in native fields, with jumps, not unit steps:
  np walks back were exact in 28 of 29 (run 138) and 56 of 58 (run 146) on the default drafts, and in every native
  walk up to 2173 units on the mixed drafts (run 149). Partly in web fields: exact on Korean text (textarea and
  Lexical-shaped, once the phantom step is skipped), but WebKit moves by characters, so text with emoji loses one unit
  per emoji unless each step is corrected (runs 145, 149, 150).
- **Step policy.** Unit steps: too slow (28-82 ms a unit, 118 s for 3230 units) and they read inconsistent contexts
  (runs 135, 140). Whole-context jumps: fast but stuck on repeated text (135). np (largest k below the context's
  length that is not a period of it and does not split a surrogate pair): never stuck, about 40 units a step, 5-7 s
  for 3230 units, 20-33 s for 14 038.
- **Line feeds**: crossed like any unit in both directions (the before-context spans line feeds; the after-context
  stops at one, so a forward step over it is a one-unit probe).
- **Start detection**: an empty before-context, then a -1 step that changes nothing for 0.5 s. An empty
  before-context alone is not the start: it also appears mid-field (false starts: up to 3 per walk at 3958 units,
  up to 53 at 14 038), and on the Lexical-shaped page the -1 at the start changes the after-context to empty without
  crossing text (phantom). There was no false *start* (a walk ending before the field's start) that the length check
  missed, but false starts that guessed a unit did corrupt texts (138 uikit p5 t1; 149 at 14 038).
- **End detection**: an empty after-context, then a +1 step that changes nothing for 0.5 s. False ends: two in 146
  (textarea p5 t1 at 39 of 318 units; lexical p5 t2's last forward walk at the phantom position, before and after
  both empty) and one in 145 (swiftui xlong t2 at 8772 of 14 038).
- **Back where it began?** After a walk back that reached the start, one move forward by the walked length landed
  exactly at the end in native hosts up to 3230 units (`r1` in every native read of run 146 and the short ones of
  149); not always beyond that or in 153 (149: uikit xlong t1 `rx`, swiftui xlong t1 `rx,rs`; 153: `rx` in p5 t1,
  l5 t2, longmid and `rx,rx` in all 7 long reads), and not on the Lexical-shaped page (`rx`, the phantom). So K1b
  confirms the end with a forward walk after the move.
- **Select all**: collapse with +1 (lands at the end) and walk; -1 lands one before the end, 0 does nothing for 1 s.
  `selectedText` during select all is a window (43 units), not the selection.
- **Time on 3230 units**: unit walk 118 s (and capped at 1700 steps in the probe); np walk back 5.4-6.7 s; a read of
  two np walks 14.0-15.1 s native (146, with 1 s of a useless big move), 37.7-39.0 s web; forward walks to the end are about 4x slower per unit
  than walks back (138: 20-23 s for 3230), so a cursor near the start of a long text costs most.
- **Mixed text (emoji)**: native hosts read it exactly up to 2173 units with the surrogate-safe np step (149: 16 of
  16; 153: 14 kept, all exact). Web hosts move by characters (150), and neither the correction nor the strict rule
  made a web read with emoji exact (153: all rejected, safely).
- **Long fields**: 3230-3958 units work with the strict read (154, 155: native 12 of 14 kept, all exact, 10.8-15.4 s a
  read); at 14 038 units every native read was wrong or rejected (145, 149, 153): empty and lagging contexts pile up.
- **Verdict: partly.** Works for native fields up to about 4000 units (proven for the strict read by 154 and 155,
  without emoji; with emoji only up to 2173 units, 149 and 153), and for web fields without emoji (154, 155: every
  kept web read exact). Does not work for web fields with emoji or for fields of 14 000 units. Over runs 153-155 the
  strict read kept 62 of 87 reads, all exact, and refused every wrong one.

## Recommended K1b read (probe evidence, not shipped code)

1. **Selection**: if `selectedText` is set, collapse it with `adjustTextPosition(+1)` and read the whole field as
   below (a select-all is the only selection the walk can read: the selection's start is not visible). A short
   selection the user made stays the existing selection path; a guess, not measured here.
2. **To the end**: walk forward by `safeJump(after, forward)` until the after-context is empty, then +1; the end is a
   +1 that changes nothing for 0.5 s. Do not use one big move (146).
3. **Back to the start, twice**: from the end, step back by `safeJump(before)`: the largest k < before.count that is
   not a period of the before-context and does not land before a low surrogate. Settle each step until two polls
   20 ms apart agree (up to 5). The piece moved over is `before.suffix(k)`; check that the new before-context ends
   with what the old one kept and the new after-context starts with the piece. If not, the step is bad (no
   correction, see 6).
   An empty before-context: wait up to 0.3 s for it to come back; then -1; no change for 0.5 s = the start; a change
   that leaves the before-context empty = a phantom (skip it). After the first walk, move forward by its length and
   confirm the end; then walk back again.
4. **Accept** only when both walks reached the start, read the same units, and had no bad step, and the last forward
   walk found the end (the cursor is then at the end for Replace). Do not require that last walk to move 0 units:
   that refused 8 exact reads in 154 and 155 and no wrong one (worked out from the logs, not run). Otherwise show the cut-short message ("Could not read the whole text. Select all, then
   tap again." or one that says the text is too long).
5. **Caps**: stop the first walk back when it has read 4000 UTF-16 units, and the whole read at 20 s, with that
   message; show progress after 2 s. Measured (154, 155): native two-walk reads take 3.6-4.9 s at 71-378 units,
   10.8-15.4 s at 3230-3958; web ones up to 46.6 s when the cursor starts far from the end (the forward walk is the
   slow part), so the 20 s cap refuses such web reads; at 14 038 units every read failed. No two-walk read took less
   than 3.0 s (149: 3.1 s for 143 units; 153-155: 3.6 s and up), so the current FieldReadBudget of 2 s fits none of them: K1b needs
   its own budget. 4000 units and 20 s are a proposal from these timings, not a user test.
6. **Web fields with emoji**: refuse (cut-short message) rather than correct: the characters correction fixed most
   but not all units (153). Native hosts: never apply it (153: it made long walks too long).

## Not proven

- Real phones (only the iOS 26.5 simulator), real apps (Instagram, Gmail, Notes), and their editors; the web results
  are from the read-probe page in a WKWebView.
- Text with combining marks, flag or ZWJ emoji, or variation selectors (only single-scalar emoji were tested), and
  decomposed Hangul.
- Why empty before-contexts appear mid-field and why they get frequent in long fields (a guess: the host resyncs its
  window while the cursor moves fast).
- Whether a user accepts 11-15 s for 3000-4000 units; the cap is a proposal.
- The looser keep rule (4.) was not run.
- The strict read at 3000-4000 units with emoji (149 and 153 only had 2173 units with emoji below 14 038).
- Why web steps over 2 emoji fit neither k nor k + pairs (153: 2 bad steps a walk on p5).
- Whether waiting longer than 0.3 s, or a smaller k, makes 14 000-unit native reads exact.

## State

- Branches (each cut from `origin/diag/p1-walk-back` with the RECORD parse fix cae21c5, never merged, no PR):
  `diag/p1-walk-back-unit` f3f2623, `-unique` 1233d72, `-np` 3293a10, `-mix` 3182f20, `-k1b` 71f21ff, `-safe`
  340f403, `-units` 4a2110a, `-strict` 471e282, and cut from `-strict`: `-strictlong` 57c5539 (default drafts),
  `-strictlong-unique` abe62c8 (unique Korean drafts). The candidate read is `FieldText.walkRead` on `-strict` (on
  top of `-safe`), probe code only.
- Read a folder: `git fetch origin ci-shots`, copy `report.txt checks.txt keyboard-log.txt ui-log.txt` from
  `runs/<folder>/` into a directory, run `python3 -I docs/research/2026-11-21-walk-back-analyze.py <dir>` (`--steps`
  for every step line).
- Next, if K1b goes ahead: real-phone checks in Notes, Instagram and Gmail (the hosts K1b is for), a draft with ZWJ
  and flag emoji, and a user-facing time limit test.
