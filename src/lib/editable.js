// Reading and writing a contenteditable box, shared by the site composers (content/dom.js) and the any-site writer
// (generic/writer.js). No site knowledge here: editors are found by their own DOM markers.

const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIGCAPTION|FIGURE|FOOTER|H[1-6]|HEADER|HR|LI|MAIN|OL|P|PRE|SECTION|TABLE|TR|UL)$/;
const SKIP = /^(SCRIPT|STYLE|TEMPLATE)$/;

// One \n between blocks and per <br>. innerText puts a blank line between <p>s (ProseMirror, Quill, Lexical).
export function editableText(root) {
  let out = '';
  const walk = (n) => {
    if (n.nodeType === 3) { out += n.textContent; return; }
    if (n.nodeType !== 1 || SKIP.test(n.nodeName)) return;
    if (n.nodeName === 'BR') { out += '\n'; return; }
    const block = BLOCK.test(n.nodeName);
    if (block && out && !out.endsWith('\n')) out += '\n';
    n.childNodes.forEach(walk);
    if (block && !out.endsWith('\n')) out += '\n';
  };
  root.childNodes.forEach(walk);
  return out.replace(/\n$/, '');
}

// Editors whose own paste handler keeps every line of a text/plain paste, also one dispatched from a content script
// (fix track C2, step 0): Lexical (Instagram, WhatsApp), Draft.js and Slate. One insertText merges the lines in
// Lexical, crashes Draft.js and leaves Slate's model behind. Found by DOM marker only: an editor that handles a paste
// without preventDefault (Quill 1.x) would get the text twice if defaultPrevented picked the path.
const PASTE_EDITORS = '[data-lexical-editor], .public-DraftEditor-content, [data-slate-editor]';

// A Lexical draft whose last block holds several lines and ends in a line break (<p>a<br>b<br><br></p>: Shift+Enter
// after the last line, or Enter in plain-text Lexical). After a select-all, Lexical's own selection ends after that
// block's first line, so a paste replaces only that line (step 0, Lexical 0.12.6 to 0.53.0). The content script cannot
// see Lexical's selection, so such a draft is never written. One line, or a single-line last paragraph, is written.
export function cutsShort(el) {
  if (!el.matches?.('[data-lexical-editor]')) return false;
  const kids = [...(el.lastElementChild?.children ?? [])];
  const brk = kids.findIndex((k) => k.nodeName === 'BR');
  return kids.at(-1)?.nodeName === 'BR' && brk >= 0 && kids.slice(brk).some((k) => k.nodeName !== 'BR');
}

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
