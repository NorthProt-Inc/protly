const TEXT_TYPES = new Set(['', 'text', 'search', 'email', 'url', 'tel']);
const MAX_DEPTH = 10;

// isContentEditable is the browser's answer; the [contenteditable] walk covers jsdom, which does not implement it.
function isEditable(el) {
  if (el?.isContentEditable === true) return true;
  const c = el?.closest?.('[contenteditable]');
  return !!c && c.getAttribute('contenteditable').toLowerCase() !== 'false';
}

// An element's shadow root, open or closed. chrome.dom reaches a closed root (a web component's field, another
// extension's injected UI) from a content script, also one run by executeScript (checked in Chrome 156); outside
// an extension only open roots are seen.
function rootOf(el) {
  try {
    return globalThis.chrome?.dom?.openOrClosedShadowRoot?.(el) ?? el.shadowRoot ?? null;
  } catch {
    return el.shadowRoot ?? null;
  }
}

// The focused element, through open shadow roots and same-origin iframes. A cross-origin frame gives
// { el: null, blocked: true }: this frame cannot see inside it. { closed: true } also enters closed roots, for the
// write guard only: a box in a closed root is not a target, since its events reach protly's listeners retargeted
// to the host (composedPath leaves the box out), so the card could not tell the box from the page.
export function deepActive(doc, { closed = false } = {}) {
  let d = doc;
  let el = d.activeElement;
  for (let i = 0; i < MAX_DEPTH && el; i++) {
    const root = closed ? rootOf(el) : el.shadowRoot;
    if (root?.activeElement) { el = root.activeElement; continue; }
    if (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME') break;
    let inner = null;
    try { inner = el.contentDocument; } catch {}
    if (!inner) return { el: null, doc: d, blocked: true };
    d = inner;
    el = d.activeElement;
  }
  return { el, doc: d };
}

// 'text' | 'contenteditable' | null
export function classify(el) {
  if (!el || !el.tagName) return null;
  if (el.tagName === 'TEXTAREA') return el.readOnly || el.disabled ? null : 'text';
  if (el.tagName === 'INPUT') {
    const type = (el.getAttribute('type') || '').toLowerCase();
    return TEXT_TYPES.has(type) && !el.readOnly && !el.disabled ? 'text' : null;
  }
  return isEditable(el) ? 'contenteditable' : null;
}

function editableRoot(el) {
  let r = el;
  while (r.parentElement && isEditable(r.parentElement)) r = r.parentElement;
  return r;
}

// { el, doc, kind } for the focused text box, or null.
export function findTarget(doc) {
  const { el, doc: d } = deepActive(doc);
  const kind = classify(el);
  if (!kind) return null;
  return { el: kind === 'contenteditable' ? editableRoot(el) : el, doc: d, kind };
}

// The page selection, preferring the focused frame. rect() re-reads the range so a card follows scrolling;
// node is the range's common ancestor.
export function selectionInfo(doc) {
  const { doc: inner } = deepActive(doc);
  for (const d of inner === doc ? [doc] : [inner, doc]) {
    const sel = d.getSelection?.();
    const text = sel ? sel.toString() : '';
    if (!text.trim()) continue;
    const range = sel.getRangeAt(0).cloneRange();
    return { doc: d, text, node: range.commonAncestorContainer, rect: () => { try { return range.getBoundingClientRect(); } catch { return null; } } };
  }
  return { doc, text: '', node: null, rect: () => null };
}
