# Language spans inside a draft (`fr:...;`)

Date: 2026-11-08. Branch: feat/whatsapp (worktree /home/cyan/projects/protly-whatsapp). Scope: the Chrome extension.
Rev 2: applies the first plan review. Rev 2.1: the second review's test and wording changes (PASS WITH CHANGES).

## Problem

A language prefix only counts at the very start of a draft (`parseLangPrefix`, `^\s*([a-z]{2,3}):`). The owner
writes `... fr:안녕하시오.` in the middle of a Korean draft and the whole draft, `fr:` included, goes out in the
thread's language (English), as if the prefix were text.

## Goal (owner, 2026-11-08)

The text from a language code's `:` up to the next `;` is translated into that language; the rest of the draft goes
into the usual target. Example: `오늘 고마웠어 fr:정말 고마워; 다음에 또 보자` -> English, a French middle part, English
again, in one message.

## Rules

1. **A leading prefix is unchanged**: `ru: ...` at position 0 sets the whole draft's language, with or without a `;`
   later (`ru: 미안;; 늦었어` stays all Russian). `lang`, the chip and `decideBox`'s non-Korean case (`no: ...` in an
   English box) behave exactly as today.
2. **Spans open only after position 0**, at a known non-Korean code from `LANG_NAMES`, **lowercase only**, followed
   by `:`, optional spaces, and **Hangul right away**. Not after an ASCII letter or digit. Opener regex:
   `(?<![A-Za-z0-9])([a-z]{2,3}):\s*(?=[ᄀ-ᇿ㄰-㆏가-힯])`, then the code checked against `LANG_NAMES` (not `ko`).
   So `ID: abc 추가해줘`, `UK: 런던`, `No: 3`, `http://`, `10:30`, `abc:` and `ok:` never open one, while
   `고마워fr:안녕` does.
3. **A span closes at a single `;`**, which is dropped. A run of two or more `;` (`;;`, the sweat emoticon) is text and
   does not close the span. With no closing `;`, the span runs to the end of the draft. A `;` outside any span is text.
   Span text is not trimmed; spaces after the closing `;` stay outside it. A `;)` emoticon inside a span closes it
   (accepted). Known false positive, accepted because every path previews before sending: a lowercase `id:홍길동`
   mid-draft opens an Indonesian span.
4. Spans do not nest: an opener inside an open span is text. A leading prefix plus a mid span is fine:
   `ru: 안녕 fr:고마워;` -> `lang: 'ru'` with a French part.
5. Polish is untouched: spans only matter on the translate path (a draft with Hangul).

## Design

- `src/lib/lang.js`: `parseLangPrefix(s)` keeps its signature and result `{ lang, text }`. After the leading-prefix
  step (unchanged), every span in the rest becomes `<fr>정말 고마워</fr>` inside `text`. One parser for the three
  callers.
- `src/generic/decide.js:10`: send `p.text`, not the raw `text`, when there is no leading prefix (today it ignores
  `p.text` in that branch, so spans would never reach the box request).
- `src/lib/prompts.js`: one rule line in `OUTGOING_SYSTEM` and `EMAIL_SYSTEM` (the box prompt reuses
  `OUTGOING_SYSTEM`): "A part of the draft wrapped in a language tag such as `<fr>...</fr>` goes into that language;
  everything else goes into TARGET. Never write the tags themselves. back_translation stays all Korean."
  `EMAIL_SYSTEM`'s `lang` line becomes "the ISO 639-1 code of the main language you wrote in (TARGET, not a tagged
  part)", since Gmail stores `r.lang` as the chip (`gmail/compose.js:238`). Chat and box already return
  `lang: target` from the background.
- **No tag stripping.** `parseOutgoing` also parses polish results, where `<br>` or `<em>` can be real text, and every
  path shows a preview before anything is sent. Cut.
- Esc, Undo, the hover original and the `sent` record keep the raw draft (`state.korean`), so `fr:...;` comes back
  exactly as typed (verified by the review).

## Tests (red first)

- `tests/lang.test.js`: mid-draft span; two spans; no `;` runs to the end; `;;` inside a span is text and does not
  close it; leading `ru:` with a later `;` unchanged (whole draft, no span); leading `ru:` plus a mid `fr:...;` keeps
  `lang: 'ru'` with a `<fr>` part; `고마워fr:안녕;` opens; `ID: abc 추가해줘`, `UK: 런던`, `http:`, `10:30`, `ok:`,
  `ko:` stay text; `fr: Bonjour` (no Hangul after the colon) stays text; an opener inside a span is text. Rename the
  existing "a late prefix stays text" case (line 62-63), which is now only true for a late prefix without Hangul.
- `tests/lang.test.js` also: `안녕; 잘가` unchanged; `fr:고마워; ;` closes at the first `;`; `fr:고마워;;; 응` does not
  close; `fr:정말 고마워; 다음에` gives `<fr>정말 고마워</fr> 다음에`; uppercase non-openers tested mid-draft
  (`x ID: abc 추가해줘`); the `id:홍길동` false positive pinned as documented behaviour.
- `tests/prompts.test.js`: the tag rule is in the outgoing and email system prompts (the box system already equals
  the DM one, `prompts.test.js:164`); the email `lang` line names the main TARGET.
- `tests/generic-decide.test.js`: a Korean box draft with a mid span sends the tagged text with `lang: 'en'`; a
  leading `ru: 안녕 fr:고마워;` gives `lang: 'ru'` with a `<fr>` part.
- `tests/gmail-compose.test.js`: a mid span sends the tagged text with `lang: 'auto'`.
- `tests/preview.test.js`: a draft with a span sends `lang: null` and the tagged text; Esc restores the raw draft.

## Live check (owner's go; self chat only)

`오늘 고마웠어 fr:정말 고마워; 다음에 또 보자` in "Message yourself": preview shows English + French + English, no tags,
the back-translation is Korean; Esc brings back the raw draft with `fr:` and `;`.

## Out of scope

- The iPhone keyboard (`ios-app/ProtlyCore/Sources/ProtlyCore/Languages.swift` mirrors the start-only prefix).
  Follow-up once the extension behaviour is confirmed.
