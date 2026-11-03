# Polish styles by prefix (idea, 2026-11-02)

Status: discussed, not planned. Post-V1. No code written.

## Idea

More English Polish styles, chosen on the keyboard by a slash prefix, the way a language is chosen by `ru:`:

| Prefix | Style |
|--------|-------|
| `for/` | formal |
| `cas/` | casual |
| `con/` | concise |
| `warm/` | warm |

Owner picked the prefix over UI switches (style chips on the result card, long-press on Polish, a bar toggle)
because it needs no UI work.

## Why it is cheap

- No collision with the language prefix: `Languages.prefix(of:)` takes 2-3 letters plus `:` only
  (`ios-app/ProtlyCore/Sources/ProtlyCore/Languages.swift:35`). A separate slash parser also takes 4-letter `warm`.
- Strip the prefix and add one `STYLE: <name>` line to the user message (`ActionAPI.userMessage`, MODE fix). The
  system prompt stays byte-identical, so prompt caching holds.
- `BarAction.title` shows `Polish · Formal`, so the user sees the prefix was read.
- Scope: Core parser, userMessage, BarAction label, a few prompt lines in `ios/keyboard-prompt.txt`, tests.
  About half a day. `/` sits on the 123 layer, the same cost as `:` today.

## Open questions (owner)

1. Does a style also apply to a Korean draft (`for/ 내일 미팅 가능?` -> translate out in formal English)?
   Recommended: yes, it is the same English output.
2. With a language prefix too (`ru: for/ ...`): accept both, any order? Recommended: yes.
3. Chrome extension too, or keyboard only? (The extension shares the style text through `src/lib/style.js`.)
4. Style wording. `src/lib/style.js` is the owner's verbatim text, pinned by `tests/style.test.js`, so the owner
   writes or approves these. Draft, with the conflicts against the current voice rules:
   - `for/`: polite and professional, no slang, no contractions, still plain words. Overrides "Contractions are fine".
   - `cas/`: like texting a friend, short sentences, contractions and slang fine.
   - `con/`: as short as possible while keeping every fact and request. Overrides "Length stays close to the draft".
   - `warm/`: friendly and kind. Open: do the banned phrases (`I'd love to`, `excited to`, ...) still apply?
   - Every style keeps the Meaning rules (no fact, number, request or hedge dropped) and Canadian spelling.

## Next step

Answer 1-4, then write a plan doc in `docs/plans/` before any code.
