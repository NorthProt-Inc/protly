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
function paragraphs(doc, lines) {
  return lines.map((l) => {
    const p = doc.createElement('p');
    if (l) p.textContent = l; else p.appendChild(doc.createElement('br'));
    return p;
  });
}
export function setLines(el, lines) {
  el.replaceChildren(...paragraphs(el.ownerDocument, lines));
}

// Writes nodes where the selection is, as the editors do: in place of the whole box when the selection covers it (the
// writers' select-all), at the selection otherwise, and nowhere when the selection is outside the box. A dropped or
// collapsed select-all therefore leaves the old text in the box and fails the write check.
function writeAtSelection(el, nodes) {
  const sel = el.ownerDocument.getSelection();
  if (!sel.rangeCount || !el.contains(sel.anchorNode) || !el.contains(sel.focusNode)) return;
  if (sel.toString() === el.textContent) { el.replaceChildren(...nodes); return; }
  const range = sel.getRangeAt(0);
  range.deleteContents();
  const frag = el.ownerDocument.createDocumentFragment();
  frag.append(...nodes);
  range.insertNode(frag);
}

// el becomes an editor of kind 'lexical' | 'draft' | 'slate' (its DOM marker), or a plain contenteditable (kind
// null, like Quill 1.x: it handles a paste on its own without preventDefault, and insertText keeps lines).
// paste(text): what the editor renders for a paste (a string: one <p> per line; undefined: the callback rendered
// it itself); null: it ignores pastes (no preventDefault, no change). Returns the log of pastes (their text) and
// insertText calls.
export function fakeEditor(el, { kind = 'lexical', paste = (t) => t } = {}) {
  const doc = el.ownerDocument;
  addClipboard(doc.defaultView);
  if (kind) el.setAttribute(...MARKERS[kind]);
  Object.defineProperty(el, 'innerText', { configurable: true, get: () => innerTextOf(el) });
  const log = { pastes: [], inserts: [] };
  el.addEventListener('paste', (e) => {
    const text = e.clipboardData.getData('text/plain');
    log.pastes.push(text);
    if (!kind) { writeAtSelection(el, paragraphs(doc, text.split('\n'))); return; } // Quill-like: no preventDefault
    if (paste === null) return;
    e.preventDefault();
    const shown = paste(text);
    if (shown !== undefined) writeAtSelection(el, paragraphs(doc, shown.split('\n')));
  });
  doc.execCommand = (...args) => {
    const text = args[2]; // execCommand('insertText', false, text)
    log.inserts.push(text);
    // Lexical's selection.insertText drops the line breaks.
    writeAtSelection(el, paragraphs(doc, kind === 'lexical' ? [text.replace(/\n/g, '')] : text.split('\n')));
    return true;
  };
  return log;
}

export const nonblank = (s) => s.split('\n').map((l) => l.trim()).filter(Boolean);
