# protly

Write in Korean or English, send in English. protly is a Chrome extension and a custom iPhone keyboard that
types Korean and English on one QWERTY grid. Both translate or polish what you write with Claude.

## Chrome extension

- Built in on `instagram.com` (DMs), `web.whatsapp.com` (chats) and `mail.google.com` (drafts).
- On any other site, press `Alt+T` in a focused text box, or right-click a box or a selection and pick protly.
- Calls to the Anthropic API go through a native messaging host (`host/protly_host.py`), so the API key stays
  in that process and never reaches the page or the extension.

Install:

```bash
npm install
npm run build
```

Load the folder in `chrome://extensions` with Developer mode on (Load unpacked), then register the host with
the extension id Chrome shows:

```bash
host/install.sh <extension-id>
```

## Claude Code prompt (terminal)

`host/protly_edit.py` is an editor shim. With it set as the editor for Claude Code, Ctrl+G on a prompt draft
rewrites it in English in place (Opus, low effort, the same API key as the host): a draft that contains Hangul is
translated, an English draft is polished. A blank draft, or any other file, opens in the real editor
(`$PROTLY_EDITOR`, default `nano`). On a failure the draft is kept. Works in any terminal. Enable it in `~/.claude/settings.json`:

```json
{ "env": { "EDITOR": "/path/to/protly/host/protly_edit.py" } }
```

## iPhone keyboard

A KeyboardKit-based keyboard with Translate, Polish and Read clipboard in its bar. Code is in `ios-app/`:
the xtool app (container `Protly`, extension `ProtlyKeyboard`) and the Swift package `ios-app/ProtlyCore`
for the logic. KeyboardKit 9.9.1 is vendored in `ios-app/Vendor/KeyboardKit`; every change from upstream is
listed in `VENDORED.md` and `protly.patch`.

The phone build uses `xtool dev build` on the laptop. `ios-app/Sources/ProtlyKeyboard/Secrets.swift` is
gitignored and written by `ios-app/scripts/make-secrets.sh`. Never commit it.

## Layout

| Path | Contents |
|------|----------|
| `src/`, `popup/`, `options/`, `manifest.json` | extension |
| `host/` | native messaging host and installer, Claude Code editor shim (`protly_edit.py`) |
| `ios-app/` | iPhone app and keyboard |
| `scripts/build.mjs` | extension build |
| `tests/` | extension tests |
| `docs/` | plans, research, security reviews, phone notes |

## Test

Tests run offline.

```bash
npm test                                          # extension and host
swift test --package-path ios-app/ProtlyCore      # needs a Swift toolchain
```

Both pass before every commit. Plans of record and conventions are in `CLAUDE.md`.
