// Fake rich editors for the write tests, built on what the Chromium harness found the real ones do (diagnosis P1b,
// fix track C2): Lexical, Draft.js and Slate handle a text/plain paste themselves, call preventDefault and keep every
// line; Lexical merges the lines of one execCommand('insertText') into one. jsdom has no DataTransfer, ClipboardEvent
// or innerText, so this file adds the little a paste handler and the composer read use.

const MARKERS = {
  lexical: ['data-lexical-editor', 'true'],
  draft: ['class', 'notranslate public-DraftEditor-content'],
  slate: ['data-slate-editor', 'true'],
};

export function addClipboard(win) {
  if (win.ClipboardEvent) return;
  win.DataTransfer = class DataTransfer {
    #data = new Map();
    setData(type, value) { this.#data.set(type, String(value)); }
    getData(type) { return this.#data.get(type) ?? ''; }
    get types() { return [...this.#data.keys()]; }
  };
  win.ClipboardEvent = class ClipboardEvent extends win.Event {
    constructor(type, init = {}) {
      super(type, init);
      this.clipboardData = init.clipboardData ?? null;
    }
  };
}

// innerText as Chrome gives it for these editors: <p> blocks apart by a blank line, <br> a line break.
function innerTextOf(el) {
  const flat = (n) => [...n.childNodes].map((c) => (c.nodeName === 'BR' ? '\n' : c.nodeType === 1 ? flat(c) : c.data)).join('');
  const blocks = [...el.children].filter((c) => c.nodeName === 'P');
  return blocks.length ? blocks.map(flat).join('\n\n') : flat(el);
}

// One <p> per line, as rich Lexical renders a paste; an empty line is a <p> holding a <br>.
export function setLines(el, lines) {
  const doc = el.ownerDocument;
  el.replaceChildren(...lines.map((l) => {
    const p = doc.createElement('p');
    if (l) p.textContent = l; else p.appendChild(doc.createElement('br'));
    return p;
  }));
}

// el becomes an editor of kind 'lexical' | 'draft' | 'slate' (its DOM marker), or a plain contenteditable (kind
// null, like Quill 1.x: it handles a paste on its own without preventDefault, and insertText keeps lines).
// paste(text): what the editor renders for a paste (default: every line); null: it ignores pastes (no preventDefault,
// no change). Returns the log of pastes (their text) and insertText calls.
export function fakeEditor(el, { kind = 'lexical', paste = (t) => t } = {}) {
  const doc = el.ownerDocument;
  addClipboard(doc.defaultView);
  if (kind) el.setAttribute(...MARKERS[kind]);
  Object.defineProperty(el, 'innerText', { configurable: true, get: () => innerTextOf(el) });
  const log = { pastes: [], inserts: [] };
  el.addEventListener('paste', (e) => {
    const text = e.clipboardData.getData('text/plain');
    log.pastes.push(text);
    if (!kind) { setLines(el, text.split('\n')); return; } // Quill-like: its own insert, no preventDefault
    if (paste === null) return;
    e.preventDefault();
    setLines(el, paste(text).split('\n'));
  });
  doc.execCommand = (cmd, ui, text) => {
    log.inserts.push(text);
    setLines(el, kind === 'lexical' ? [text.replace(/\n/g, '')] : text.split('\n')); // Lexical drops the breaks
    return true;
  };
  return log;
}

export const nonblank = (s) => s.split('\n').map((l) => l.trim()).filter(Boolean);
