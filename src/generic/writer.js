import { cutsShort, editableText, insertAll } from '../lib/editable.js';

// Reads and writes a text box on any site. textarea/input: setRangeText plus an input event, which React-style
// controlled inputs notice (their value tracker sees the change). contenteditable: select all and insertAll() (a paste
// on Lexical, Draft.js and Slate, execCommand('insertText') elsewhere), the path the Instagram writer uses, so the
// editor's own undo and state stay in sync.
export const SELECT_SETTLE_MS = 60; // editors such as Lexical sync their selection on selectionchange
export const VERIFY_MS = 300; // Slate and Draft.js cancel beforeinput and render the text a tick later
const POLL_MS = 20;

const norm = (s) => (s ?? '').replace(/\s+/g, ' ').trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function readBox(t) {
  if (t.kind === 'text') return t.el.value;
  return editableText(t.el);
}

// true once the box holds text (whitespace-normalized), polling up to ms for editors that render late.
export async function boxHolds(t, text, ms = VERIFY_MS) {
  const want = norm(text);
  const end = Date.now() + ms;
  for (;;) {
    if (norm(readBox(t)) === want) return true;
    if (Date.now() >= end) return false;
    await sleep(Math.min(POLL_MS, Math.max(0, end - Date.now())));
  }
}

function setValue(el, text) {
  try {
    el.setRangeText(text, 0, el.value.length, 'end');
  } catch {
    // email inputs have no selection API: use the native setter so frameworks still see a change
    const proto = Object.getPrototypeOf(el);
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
  }
  const win = el.ownerDocument.defaultView;
  const Ev = win?.InputEvent || win?.Event;
  el.dispatchEvent(new Ev('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
}

// true when the box ends up holding text, false when the write failed (the caller restores) or was refused with the
// box untouched (a Lexical draft cutsShort() turns down), null when stillOk() said no right before writing (nothing
// was written). textarea/input are written without focusing.
export async function writeBox(t, text, { settleMs = SELECT_SETTLE_MS, verifyMs = VERIFY_MS, stillOk = () => true } = {}) {
  const { el } = t;
  if (!el.isConnected) return false;
  if (t.kind === 'text') {
    if (!stillOk()) return null;
    setValue(el, text);
  } else {
    if (cutsShort(el)) return false;
    el.focus();
    el.ownerDocument.getSelection().selectAllChildren(el);
    await sleep(settleMs);
    if (!el.isConnected) return false;
    if (!stillOk()) return null;
    el.focus();
    insertAll(el, text);
  }
  return boxHolds(t, text, verifyMs);
}
