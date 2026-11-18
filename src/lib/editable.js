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

// The child elements of a Lexical editor's last block; a trailing list's block is its last item.
function lastBlockKids(el) {
  let block = el.lastElementChild;
  while (block && (block.nodeName === 'UL' || block.nodeName === 'OL')) block = block.lastElementChild;
  return [...(block?.children ?? [])];
}

// A Lexical draft whose last block ends in a <br> (a line break: Shift+Enter after the last line, Enter in plain-text
// Lexical; or the caret <br> after an inline decorator) and holds more than one inline node before it
// (<p>a<br>b<br><br></p>, <p><span>a </span><strong>b</strong><br><br></p>). After a select-all, Lexical's own selection
// then ends after that block's first inline node, so a paste replaces only that (step 0, Lexical 0.12.6 to 0.53.0;
// review of C2 for the inline shapes). The content script cannot see Lexical's selection, so such a draft is never
// written. A list's last block is its last item. One inline node and a line break (<p><span>a</span><br><br></p>), and
// an empty last paragraph (<p><br></p>), are written whole.
export function cutsShort(el) {
  if (!el.matches?.('[data-lexical-editor]')) return false;
  const kids = lastBlockKids(el);
  return kids.at(-1)?.nodeName === 'BR' && kids.slice(1).some((k) => k.nodeName !== 'BR');
}

// What to do about a draft cutsShort() refuses, as the user sees it. A <br> before the last one is a real empty line.
// A lone last <br> is Lexical's caret <br> after an inline decorator, which the user cannot see: Lexical adds it only
// while the block's last child is a line break or an inline decorator (0.53 LexicalReconciler.ts,
// $isLastChildLineBreakOrDecorator), so a typed space, a text node after the decorator, removes it.
export function cutShortMessage(el) {
  return lastBlockKids(el).at(-2)?.nodeName === 'BR'
    ? 'Delete the empty line at the end of the message, then try again.'
    : 'Type a space at the end of the message, then try again.';
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
