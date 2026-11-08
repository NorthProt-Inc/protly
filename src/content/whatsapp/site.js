// WhatsApp Web site adapter. Every WhatsApp Web DOM assumption lives here (spike: docs/spike-notes-whatsapp.md).
import { start as run } from '../main.js';
import { textOf } from '../dom.js';

export const SEL = {
  threadRoot: '#main', // replaced on every chat switch
  title: 'header [data-testid="conversation-info-header-chat-title"]',
  messageRow: '[data-testid^="conv-msg-"]',
  messageText: '[data-testid="selectable-text"]',
  quote: '[data-testid="quoted-message"]',
  meta: '[data-testid="msg-meta"]',
  composer: 'footer div[contenteditable="true"][role="textbox"]',
};
// Own messages carry a delivery status label. English UI only: in another UI language own messages read as the
// partner's (plan Decision 2).
const OWN_STATUS = new Set(['Read', 'Delivered', 'Sent', 'Pending']);

// cyrb53 (public domain), a sync 53-bit string hash: the thread id is needed inside a keydown handler, and the
// page shows no chat id, only the title. 14 lowercase hex chars. Changing it re-keys every stored chat.
export function cyrb53(str) {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16).padStart(14, '0');
}

const mainOf = (doc) => doc.querySelector(SEL.threadRoot);

// textOf, not textContent: names render emoji as <img alt>, so "🔥🔥" must not read empty and "Mom" and "Mom ❤️"
// must differ.
export function chatTitle(doc) {
  const el = mainOf(doc)?.querySelector(SEL.title);
  return el ? textOf(el).trim() || null : null;
}

// Never null while a chat is open: a title selector miss must still give the badge and the Enter guard.
export function threadIdFor(doc) {
  if (!mainOf(doc)) return null;
  const t = chatTitle(doc);
  return t ? `wa-${cyrb53(t)}` : 'wa-untitled';
}

export function senderOf(row) {
  const labels = row.querySelectorAll(`${SEL.meta} [aria-label]`);
  return [...labels].some((n) => OWN_STATUS.has(n.getAttribute('aria-label').trim())) ? 'me' : 'partner';
}

// The body text, not the quoted message a reply carries.
export const textElOf = (row) => [...row.querySelectorAll(SEL.messageText)].find((n) => !n.closest(SEL.quote)) ?? null;

// Text bubbles only, top to bottom. Rows without a text element (media, stickers) are skipped.
export function readMessages(root) {
  const out = [];
  for (const row of root.querySelectorAll(SEL.messageRow)) {
    const textEl = textElOf(row);
    const text = textOf(textEl).trim();
    if (text) out.push({ row, textEl, text, from: senderOf(row) });
  }
  return out;
}

export const SITE = {
  key: 'whatsapp',
  name: 'WhatsApp',
  threadId: () => threadIdFor(document),
  findThreadRoot: (doc) => (chatTitle(doc) ? mainOf(doc) : null), // no title: waitForThread times out -> badge
  readMessages,
  findComposer: (doc) => mainOf(doc)?.querySelector(SEL.composer) ?? null,
  cardAnchor: (c) => c.closest('footer') || c.parentElement,
};

export const start = () => run(SITE);
