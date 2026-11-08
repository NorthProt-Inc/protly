# WhatsApp Web spike notes

Live DOM read on `https://web.whatsapp.com/` (2026-11-07), logged-in account, English UI. Only chats with no unread
messages were opened (opening a chat sends read receipts). Nothing was sent; the one composer write was cleared with
real Ctrl+A, Backspace.

## Page and navigation

- The URL never changes: `location.pathname` is `/`, no hash, no query, for every chat. A chat cannot be identified
  from the URL.
- No chat JID anywhere in the DOM: no attribute value matches `@c.us`, `@g.us`, `@lid`, `@s.whatsapp.net` or
  `@newsletter`. The message `data-id` is now a bare message key (20 or 32 alphanumerics, no `true_`/`false_` prefix,
  no chat id). The old `data-id="true_<jid>_<key>"` scheme found in older extensions is gone.
- The only chat identity in the DOM is the header title:
  `#main header [data-testid="conversation-info-header-chat-title"]` (contact name, saved name, phone number for an
  unsaved contact, or group name). The subtitle ("click here for contact info", typing, last seen) is a separate node.
- Switching chats **replaces `#main`**: the old node is disconnected, and the scroller and composer are new nodes.
  Message rows are not reused across chats (unlike Instagram). The new `#main` first renders with 1 message, then the
  full history within about 1 s.
- Sidebar: `#side`, list `#pane-side`, rows `[role="row"]`, the open chat row has `aria-selected="true"`, row title
  `span[title]`.

## Messages

| Name | Selector / rule | Evidence |
|---|---|---|
| thread root | `#main` | Has `data-testid` and `data-chat-theme-*` attributes; replaced per chat |
| scroller | `[data-testid="conversation-panel-messages"]` | The overflow container holding the rows |
| message row | `[data-testid^="conv-msg-"]` (also carries `data-id`) | 19 in a 1:1 chat, 13 in a group; the parent is `[role="row"]` |
| message text | first `[data-testid="selectable-text"]` that is not inside `[data-testid="quoted-message"]` | A reply holds two: the quoted one (`quoted-mention` class, inside `quoted-message`) and the body |
| sender = me | `[data-testid="msg-meta"]` contains an `[aria-label]` reading `Read`, `Delivered`, `Sent` or `Pending` (trimmed) | Every own message in both chats had one; no partner message did. Labels are UI-language dependent (English here) |
| author line | `.copyable-text[data-pre-plain-text]`, value `[HH:MM, YYYY-MM-DD] Name: ` | The own name is the viewer's push name; partners carry their contact name |
| media | rows without `selectable-text` (`image-thumb`, stickers) | Skipped, as on Instagram |

`tail-in` / `tail-out` icons exist only on the first message of a run, so they cannot mark direction on their own.
No `message-in` / `message-out` classes are left; class names are hashed (`x1n2onr6 ...`) and never used.

## Composer

- `#main footer div[contenteditable="true"][role="textbox"][data-lexical-editor="true"]`, `aria-label` `Type a
  message to <name>`. One match on the page (the sidebar search is not contenteditable).
- Empty `innerText` is `"\n"`, same as Instagram.
- Write: focus, `getSelection().selectAllChildren(el)`, wait 60 ms, `execCommand('insertText', false, text)` works;
  the Send button appears.
- `execCommand('delete')` after select-all returns true and leaves the text (Lexical, same as Instagram). Real Ctrl+A,
  Backspace clears it.

## Emoji (second read, 2026-11-07)

- In message bubbles an emoji is an `<img class="... emoji apple ... selectable-text" alt="😀">` inside the
  `selectable-text` span. `innerText` and `textContent` drop it; only `alt` carries the character.
- In the composer an inserted emoji stays a Unicode character in Lexical `<span>`s (no `<img>`): `innerText` of
  `hi 😀 ok` reads back exactly. Cleared afterwards with real Ctrl+A, Backspace.
- The header title of the opened chat had no `<img>`.
- Own-message status has no `data-icon` (the only `data-icon` values inside rows are `tail-in` / `tail-out`), so the
  English `aria-label` is the only direction mark found.

## CSP

`script-src blob: 'self' 'nonce-...' https://static.whatsapp.net ...`, **no** `require-trusted-types-for`. The thread
panel's `shadow.innerHTML` is allowed.

## Not checked (live check task)

- Enter interception order: WhatsApp's own Enter handler vs the window capture listener (expected to work as on
  Instagram, both are Lexical).
- Card placement above the footer, and the floating panel button against WhatsApp's layout.
- Content-script `import()` of extension modules under this CSP (works on Instagram and Gmail).

## Live check (2026-11-07, branch feat/whatsapp)

Chats opened had no unread messages. Enter and Esc were pressed only in "Message yourself"; nothing was sent.

- Past partner messages translate on open, emoji kept (a bubble with `<img alt="😓">` translated with the emoji).
  Mode followed the stored default (`Below` here), so no init race was seen.
- A -> B -> A: B showed exactly one translation per partner text bubble (8 of 8), none of A's; back in A the two
  translations were intact, no duplicates.
- Emoji bubble read: the `textOf` walk equals the bubble with each `<img>` replaced by its alt, no hidden
  descendants, alt `U+1F613`.
- Group title `YMCA Football Club ⚽`: the ⚽ is an `<img alt>` in the header title (textContent drops it), so the
  `textOf` title read is needed.
- Self chat: Korean + 😀, Enter: the box held the English translation with the emoji, card showed the original,
  the language chip and `Esc undo · Alt+Enter Opus`. Esc restored the Korean. Cleared with Ctrl+A, Backspace.
- Bug found and fixed: the card placed before `<footer>` rendered at the top of `#main` (flex column). It now goes
  inside the footer, before the composer's row, right above the box.
