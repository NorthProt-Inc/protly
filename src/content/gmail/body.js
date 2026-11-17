import { GSEL } from './selectors.js';

const BLOCK = /^(DIV|P|LI|H[1-6]|UL|OL|BLOCKQUOTE)$/;
const HIDDEN = /^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT)$/; // an email's CSS or script is not text anyone reads
const MEDIA = 'img, video, iframe';

const isBoundary = (n) => n.nodeType === 1 && (n.matches(GSEL.boundary) || !!n.querySelector(GSEL.boundary));
const isBlank = (n) =>
  n.nodeName === 'BR' ||
  (n.nodeType === 3 && !n.textContent.trim()) ||
  (n.nodeType === 1 && !n.textContent.trim() && !n.querySelector(MEDIA));

// Where the user's part lives: normally the body itself, but a reopened draft can wrap the text and the
// signature in one <div>, so descend while the first child holds a boundary without being one.
function userParent(body) {
  let p = body;
  for (;;) {
    const first = [...p.childNodes].find((n) => !(n.nodeType === 3 && !n.textContent.trim()));
    if (!first || first.nodeType !== 1 || first.matches(GSEL.boundary) || !first.querySelector(GSEL.boundary)) return p;
    p = first;
  }
}

// A <br> right after text ends that text's line (Chrome types "line<br>" before a block); it is not a blank line.
const endsLine = (kids, i) =>
  kids[i].nodeName === 'BR' && i > 0 && !isBlank(kids[i - 1]) && !BLOCK.test(kids[i - 1].nodeName);

// The user's part of parent: its children before the first quote/signature block, minus trailing blank lines (those
// separate the draft from the signature and stay untouched). With no Enter after the last line, Chrome leaves that
// line in the block that holds the signature or quote (line1<div>line2</div><div>line3<br>...<div
// class="gmail_signature">), so when the first child with a boundary is not one itself, its children before the
// boundary are taken too. The user's part of each parent is a run at its start.
function partOf(parent) {
  const kids = [...parent.childNodes];
  let end = kids.findIndex(isBoundary);
  if (end === -1) end = kids.length;
  const inner = end < kids.length && !kids[end].matches(GSEL.boundary) ? partOf(kids[end]) : [];
  if (inner.length) return [...kids.slice(0, end), ...inner];
  while (end > 0 && isBlank(kids[end - 1]) && !endsLine(kids, end - 1)) end--;
  return kids.slice(0, end);
}

export const userNodes = (body) => partOf(userParent(body));

// The body's text before its first quote or signature block, in document order. The write check reads it instead of
// userNodes, so a typed line the user's part missed still counts. Block starts and ends become line breaks, so only
// compare it with whitespace collapsed.
export function textBeforeBoundary(body) {
  const { NodeFilter } = body.ownerDocument.defaultView;
  const walker = body.ownerDocument.createTreeWalker(body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.nodeType === 1 && HIDDEN.test(n.nodeName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
  });
  const open = []; // blocks the walk is inside
  let out = '';
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    while (open.length && !open.at(-1).contains(n)) { open.pop(); out += '\n'; }
    if (n.nodeType === 3) out += n.textContent;
    else if (n.matches(GSEL.boundary)) break;
    else if (n.nodeName === 'BR') out += '\n';
    else if (BLOCK.test(n.nodeName)) { open.push(n); out += '\n'; }
  }
  return out;
}

export const hasMedia = (nodes) => nodes.some((n) => n.nodeType === 1 && (n.matches(MEDIA) || !!n.querySelector(MEDIA)));

// True when n sits inside a block that prev is outside of, as the line taken from a signature's block does.
const opensBlock = (prev, n) => {
  for (let p = n.parentNode; p && !p.contains(prev); p = p.parentNode) if (BLOCK.test(p.nodeName)) return true;
  return false;
};

// Plain text with one \n per line, matching how Gmail lays out typed text (bare first line, <div> per line).
// Inline formatting is dropped.
export function nodesToText(nodes) {
  let out = '';
  const walk = (n) => {
    if (n.nodeType === 3) { out += n.textContent; return; }
    if (n.nodeType !== 1 || HIDDEN.test(n.nodeName)) return;
    if (n.nodeName === 'BR') { out += '\n'; return; }
    const block = BLOCK.test(n.nodeName);
    if (block && out && !out.endsWith('\n')) out += '\n';
    n.childNodes.forEach(walk);
    if (block && !out.endsWith('\n')) out += '\n';
  };
  nodes.forEach((n, i) => {
    if (i && out && !out.endsWith('\n') && opensBlock(nodes[i - 1], n)) out += '\n';
    walk(n);
  });
  return out.replace(/\n$/, '');
}

// Gmail's own markup: <div>line</div>, blank line <div><br></div>. Built without innerHTML (Trusted Types).
export function textToNodes(doc, text) {
  return text.replace(/\r\n?/g, '\n').split('\n').map((line) => {
    const d = doc.createElement('div');
    if (line) d.textContent = line;
    else d.appendChild(doc.createElement('br'));
    return d;
  });
}

const homes = new WeakMap(); // a node replaceUserNodes removed -> the parent it was in

// Swap the user's part for newNodes; returns the removed nodes (for Undo). Quote and signature stay put: new nodes go
// in before the first removed node, at the start of its parent. Nodes this function removed earlier (Undo, a failed
// write check) go back to the start of the parent they came from, so a line taken from the signature's block returns
// to that block. execCommand is not used: next to a block it clones the block's class onto the new lines (spike).
export function replaceUserNodes(body, newNodes) {
  const old = userNodes(body);
  const into = old[0]?.parentNode ?? userParent(body);
  old.forEach((n) => { homes.set(n, n.parentNode); n.remove(); });
  const runs = new Map(); // parent -> the nodes that go in at its start, in order
  for (const n of newNodes) {
    const home = homes.get(n);
    const p = home && body.contains(home) ? home : into;
    if (!runs.has(p)) runs.set(p, []);
    runs.get(p).push(n);
  }
  runs.forEach((nodes, p) => p.prepend(...nodes));
  body.dispatchEvent(new body.ownerDocument.defaultView.Event('input', { bubbles: true }));
  return old;
}
