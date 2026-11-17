import { SEL, senderOf, findViewerName } from './selectors.js';
import { trusted } from '../ui/trust.js';

export const findThreadRoot = (doc) => doc.querySelector(SEL.threadRoot);
export const findComposer = (doc) => doc.querySelector(SEL.composer);

// Visible text of a bubble. WhatsApp renders emoji as <img alt="😀">, which innerText and textContent drop, so an
// element holding an <img> is walked: text nodes, <br> as a newline, img alt. Without one, the plain read as before.
export function textOf(el) {
  if (!el) return '';
  if (!el.querySelector('img')) return el.innerText ?? el.textContent ?? '';
  let out = '';
  const walk = (n) => {
    for (const c of n.childNodes) {
      if (c.nodeType === 3) out += c.data;
      else if (c.nodeName === 'BR') out += '\n';
      else if (c.nodeName === 'IMG') out += c.getAttribute('alt') ?? '';
      else if (c.nodeType === 1) walk(c);
    }
  };
  walk(el);
  return out;
}

// Text bubbles only, top to bottom. Rows without a text element (media, stickers) are skipped.
// viewer defaults to the live page's sidebar username; tests pass it explicitly.
export function readMessages(root, viewer = findViewerName(root.ownerDocument)) {
  const out = [];
  for (const row of root.querySelectorAll(SEL.messageRow)) {
    const textEl = row.querySelector(SEL.messageText);
    const text = textOf(textEl);
    if (!text.trim()) continue;
    out.push({ row, textEl, text: text.trim(), from: senderOf(row, viewer) });
  }
  return out;
}

// We never change text inside Instagram's own nodes: React may re-render and throw.
// We hide the original via a data attribute (React leaves unknown attributes alone) and add a sibling.
export function renderTranslation(m, translation, mode) {
  clearTranslation(m);
  const tr = m.textEl.ownerDocument.createElement('div');
  tr.className = `pl-tr pl-${mode}`;
  tr.textContent = translation;
  if (mode === 'replace') {
    tr.title = m.text ?? m.textEl.textContent;
    m.textEl.setAttribute('data-pl-hide', '');
  }
  m.textEl.after(tr);
}

export function clearTranslation(m) {
  m.textEl.removeAttribute('data-pl-hide');
  if (m.textEl.hasAttribute('data-pl-title')) {
    m.textEl.removeAttribute('title');
    m.textEl.removeAttribute('data-pl-title');
  }
  m.textEl.parentElement?.querySelectorAll(':scope > .pl-tr').forEach((n) => n.remove());
}

// Instagram reuses message nodes across threads, so everything we added must go on teardown.
export function clearAllTranslations(root) {
  root.querySelectorAll('.pl-tr').forEach((n) => n.remove());
  root.querySelectorAll('[data-pl-hide]').forEach((n) => n.removeAttribute('data-pl-hide'));
  root.querySelectorAll('[data-pl-title]').forEach((n) => { n.removeAttribute('title'); n.removeAttribute('data-pl-title'); });
}

// True while the row still shows the text it was read with (nodes get reused for other messages).
export function stillShows(m) {
  const el = m.textEl;
  return el.isConnected && textOf(el).trim() === m.text;
}

export function renderRetry(m, onClick) {
  clearTranslation(m);
  const b = m.textEl.ownerDocument.createElement('button');
  b.className = 'pl-tr pl-retry';
  b.textContent = '⟳';
  b.title = 'Translation failed, click to retry';
  b.onclick = (e) => { e.stopPropagation(); if (trusted(e)) onClick(); }; // a page script's click is not the user's
  m.textEl.after(b);
}

export function setHoverOriginal(m, korean) {
  m.textEl.title = korean;
  m.textEl.setAttribute('data-pl-title', '');
}

export function getComposerText(el) {
  return (el.innerText || '').replace(/\n$/, '');
}

// Editors whose own paste handler keeps every line of a text/plain paste, also one dispatched from a content script
// (fix track C2, step 0): Lexical (Instagram, WhatsApp), Draft.js and Slate. One insertText merges the lines in
// Lexical, crashes Draft.js and leaves Slate's model behind. Found by DOM marker only: an editor that handles a paste
// without preventDefault (Quill 1.x) would get the text twice if defaultPrevented picked the path.
const PASTE_EDITORS = '[data-lexical-editor], .public-DraftEditor-content, [data-slate-editor]';

// Replaces the selection (a select-all) with text: a synthetic paste on the editors above, with no insertText after it
// (a second write would double the text or land in a crashed editor), execCommand('insertText') everywhere else.
export function insertAll(el, text) {
  const doc = el.ownerDocument;
  if (!el.matches?.(PASTE_EDITORS)) {
    doc.execCommand('insertText', false, text);
    return;
  }
  const win = doc.defaultView;
  const data = new win.DataTransfer();
  data.setData('text/plain', text);
  el.dispatchEvent(new win.ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
}

// Lexical syncs its selection on `selectionchange`, so it needs a moment between selecting and inserting,
// otherwise insertText is dropped (spike-notes, Composer write). Clearing to empty is not supported by Lexical
// via execCommand; callers only write non-empty text.
export const SELECT_SETTLE_MS = 60;
// stillOk() is re-checked after the settle; false aborts the insert (thread switched, write superseded).
// Returns true when the text was inserted.
// Focus coming in from elsewhere (WhatsApp's Reply leaves it on the message row) makes Lexical restore its own caret a
// moment later, which collapses the first select-all; then insertText would append. Select once more if so.
export async function setComposerText(el, text, stillOk = () => true) {
  const sel = el.ownerDocument.getSelection();
  const flat = (t) => t.replace(/\s+/g, '');
  const selectsAll = () => !flat(el.innerText || el.textContent || '')
    || (!sel.isCollapsed && el.contains(sel.anchorNode) && flat(sel.toString()) === flat(el.innerText || el.textContent || ''));
  const select = async () => {
    el.focus();
    sel.selectAllChildren(el);
    await new Promise((r) => setTimeout(r, SELECT_SETTLE_MS));
  };
  await select();
  if (el.isConnected && stillOk() && !selectsAll()) await select();
  if (!el.isConnected || !stillOk()) return false;
  el.focus();
  insertAll(el, text);
  return true;
}
