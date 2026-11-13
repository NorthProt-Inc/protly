# A language prefix translates any draft

Date: 2026-11-12. Base: main eab314f. Scope: the Chrome extension (DM sites, Gmail) and the iPhone keyboard.
Rev 2: applies the plan review (PASS WITH CHANGES): lowercase prefix only, no composing-branch guard, the Korean-target
check stays off prefixed drafts, the prompts reword their Korean-draft line instead of adding one, Swift letter and
Hangul parity, the Gmail no-op cut.

## Goal (owner, 2026-11-12)

Today a draft without Hangul always polishes. The owner sometimes wants an English draft in another language. The
existing leading prefix does it: `ru: see you tomorrow` translates into Russian. No new button or setting.

## Rule

`prefixTarget(text)` (lang.js) and `Languages.prefixTarget(_:)` (Swift) return a language code or null:

1. The text holds no Hangul (`hasHangul` false). A draft with Hangul keeps today's path, prefix included.
2. It starts with a leading prefix of a listed code, **lowercase only** (`^\s*([a-z]{2,3}):\s*`, no `i` flag). `ID:`,
   `HR:`, `IT:`, `PT:`, `No:` and `Hi:` are common English openers and stay text. Every surface types lowercase:
   desktop composers do not autocapitalize and the keyboard turns autocapitalization off. The Korean path and
   `decideBox` keep their case-insensitive prefix.
3. The code is neither `ko` nor `en`. `ko: see you` and `en: see you` keep today's behaviour (polish, prefix and all).
4. The text after the prefix holds a letter (`\p{L}`). `ru:` alone keeps today's behaviour.

The input is the draft text without notes (`splitNotes`/`Notes.split`), as every mode decision is today.

When `prefixTarget` returns a code, the draft is translated into that language through the same request as a Korean
draft with that prefix: the prefix is dropped, back_translation stays Korean so the writer can check the meaning, Deep
and Undo work as for any translation.

Accepted risk: an English draft that opens with a lowercase listed code and a colon (`no: that's wrong`, `hi: ...`)
translates into that language. The any-site box already does this on purpose (`decideBox`), every path previews before
it writes or sends, and Undo restores the draft.

## Cut (not in this plan)

- `ko:` on an English draft (English to Korean). No surface offers Korean as an output today: the four draft prompts
  say "The translation is never Korean", the pickers drop `ko`, and back_translation is Korean. It needs its own
  prompt work. Read (keyboard) and the selection menu (Chrome) already turn English into Korean.
- Mid-draft spans in English drafts (`see you fr:demain;`). The span opener needs Hangul right after the colon so
  "ID: abc", "No: 3" and "10:30" never open one. That guard stays.
- `en:` on English. Stays a polish with the prefix in the text, as today.

## Changes

### Shared

- `tests/fixtures/prefix-target-cases.json`: `{ "text", "want" }` vectors read by `tests/lang.test.js` and by
  `LanguagesTests` through `SharedFixtures`. At least: `ru: see you` -> ru, `ru:see you` -> ru, `RU: see you` -> null, `ID: A12` -> null, `No: that's wrong` -> null,
  `  ja: thanks` -> ja,
  `yue: hi` -> yue, `no: that's wrong` -> no, `ru: 안녕` -> null (Hangul), `en: hi` -> null, `ko: hi` -> null,
  `ok: fine` -> null (not a code), `ru:` -> null, `ru: 123` -> null, `10:30 ok` -> null, `see you` -> null,
  `see you ru: later` -> null (not leading). No Hangul fillers or halfwidth jamo: lang.js `HANGUL` and
  `ActionAPI.hasHangul` differ there on purpose.

### Extension

1. `src/lib/lang.js`: export `prefixTarget(text)` (its own lowercase match, then `isCode`).
2. `src/lib/preview.js` (Instagram, WhatsApp): in idle, `enter` and `run` call `translate()` when
   `hasHangul(text) || prefixTarget(text)`; `translate()` already reads the prefix into `lang`. `freshDraft` counts a
   prefixed draft as new, outside the Korean-target check (that check exists because Korean output is all Hangul):
   preview `((hasHangul(text) && s.lang !== 'ko') || prefixTarget(text)) && norm(text) !== norm(s.shown)`, kept
   `newHangul(text, s) || (prefixTarget(text) && norm(text) !== norm(s.shown))`.
3. Send guards hold a prefixed draft as they hold Hangul, on the raw text: `holdUntrustedEnter` and the
   broken-selector branch in `src/content/outgoing.js`, `guardUnownedEnter` in `src/content/main.js`. **Not** the
   composing branch: a Korean IME mid-syllable always leaves Hangul, and a composition without Hangul is a Japanese or
   Chinese IME, whose Enter commits a candidate and must not be replayed as a translation.
4. `src/content/gmail/compose.js` `translate()`: the `fresh` test, the preview "No Korean text" check and the
   translate branch accept `prefixTarget(text)` (that branch already passes the prefix's `lang`). The button title
   (`compose.js:74`) mentions the prefix.
5. `src/generic/decide.js`: no change (a prefix already wins in a box).
6. `src/lib/prompts.js`: `OUTGOING_SYSTEM` and `EMAIL_SYSTEM` reword their first line from "Translate the Korean
   draft into the TARGET language" to "Translate the draft (usually Korean, sometimes English or another language)
   into the TARGET language". The `KOREAN DRAFT:` labels stay.

### Keyboard

7. `Languages.swift`: `prefixTarget(_:)`, same rule: lowercase checked on the raw scalars (`prefix(of:)` lowercases),
   `ActionAPI.hasHangul`, `Notes.isLetter` for the letter after the prefix.
8. `ActionAPI.mode(forText:)`: `koreanPolish -> .fix`, `hasHangul -> .out`, `prefixTarget != nil -> .out`, else `.fix`.
   `userMessage(.out)` and `BarAction.center` need no change: both already read the prefix for TARGET and the label
   (`Translate → Русский`).
9. `ios/keyboard-prompt.txt` MODE out: the header says "DRAFT is the writer's draft, usually Korean" and its first
   line "Translate the DRAFT (usually Korean, sometimes English or another language) into the TARGET language ...".
   Sync with `node scripts/sync-ios-app.mjs`. Re-measure; raise the 5200 budget only if it is passed.

## Tests first (red, then green)

- lang: the fixture cases. preview: `enter` (Polish off) and `run` on `ru: see you` give a translate effect with
  `lang: 'ru'`, `korean: 'see you'`; `en: hi` and `ID: A12` with Polish off pass; a prefixed draft typed over a shown
  translation (preview and kept, a Korean-target preview included) runs. Guards: `holdUntrustedEnter` holds `ru: see you`. Gmail:
  `ru: see you` sends a translate request with `lang: 'ru'`; in preview a new prefixed draft runs. Prompts: the new
  line is in outgoing, box and email systems and the keyboard prompt.
- Swift: the fixture cases; `mode(forDraft: "ru: see you") == .out`, `"[짧게] ru: see you"` too, `"en: hi"` and
  `"ko: hi"` `.fix`; `userMessage` of `ru: see you` names `TARGET: Russian` and sends `DRAFT:\nsee you`;
  `BarAction.center(text: "ru: see you")` is `.translate(target: "Русский")`.
- `npm test` and `swift test --package-path ios-app/ProtlyCore` pass.

## Done

Both suites green, one live call per platform path (keyboard MODE out and extension outgoing with `ru: see you`
gives Russian with a Korean back_translation), PR merged, phone reinstalled.
