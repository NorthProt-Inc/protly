// The WhatsApp Web site adapter against a synthetic chat shaped by docs/spike-notes-whatsapp.md.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { readMessages, threadIdFor, cyrb53, SITE } from '../src/content/whatsapp/site.js';
import { stillShows } from '../src/content/dom.js';
import { checkShape } from '../src/lib/messages.js';

const FIXTURE = readFileSync(new URL('./fixtures/whatsapp-chat.html', import.meta.url), 'utf8');
const chat = () => new JSDOM(FIXTURE).window.document;
const withTitle = (inner) => new JSDOM(`<div id="main"><header>${
  inner === null ? '' : `<span data-testid="conversation-info-header-chat-title">${inner}</span>`
}</header></div>`).window.document;

test('WhatsApp: readMessages reads text bubbles in order, own messages by status label', () => {
  const msgs = readMessages(chat().querySelector('#main'));
  assert.deepEqual(msgs.map((m) => [m.text, m.from]), [
    ['hello there', 'partner'],
    ['my reply', 'me'], // " Read " trimmed
    ['answer to the quote', 'partner'], // the body, not the quote; "Starred" is no status
    ['hi 😀', 'partner'], // the image-only row before it is skipped; the emoji <img> keeps its alt
    ['sent one', 'me'],
    ['going out', 'me'],
    ['queued', 'me'],
  ]);
});

test('WhatsApp: stillShows holds for an emoji bubble and fails once its text changes', () => {
  const msgs = readMessages(chat().querySelector('#main'));
  const emoji = msgs.find((m) => m.text === 'hi 😀');
  assert.equal(stillShows(emoji), true);
  emoji.textEl.querySelector('img').setAttribute('alt', '😎');
  assert.equal(stillShows(emoji), false);
});

test('WhatsApp: thread id from the header title', () => {
  const a = threadIdFor(withTitle('Alice'));
  assert.match(a, /^wa-[0-9a-f]{14}$/);
  assert.equal(threadIdFor(withTitle('Alice')), a);
  assert.notEqual(threadIdFor(withTitle('Bob')), a);
  assert.equal(threadIdFor(withTitle(null)), 'wa-untitled'); // selector miss: the guard and the badge still work
  assert.equal(threadIdFor(withTitle('   ')), 'wa-untitled');
  assert.equal(threadIdFor(new JSDOM('<body></body>').window.document), null); // no chat open
  // Emoji in names render as <img alt>: an emoji-only name is a real chat, and an emoji tells two names apart.
  assert.match(threadIdFor(withTitle('<img alt="🔥" src="data:,">')), /^wa-[0-9a-f]{14}$/);
  assert.notEqual(threadIdFor(withTitle('Mom')), threadIdFor(withTitle('Mom<img alt="❤️" src="data:,">')));
  for (const id of [a, 'wa-untitled', threadIdFor(withTitle('<img alt="🔥" src="data:,">'))]) {
    assert.doesNotThrow(() => checkShape('getThread', { threadId: id }), id); // the background accepts it
  }
});

test('WhatsApp: cyrb53 is pinned (a change would re-key every stored chat)', () => {
  assert.equal(cyrb53('a'), (7929297801672961).toString(16).padStart(14, '0')); // published reference value
  assert.equal(cyrb53('b'), (8684336938537663).toString(16).padStart(14, '0'));
  assert.equal(cyrb53('Test Partner').length, 14);
});

test('WhatsApp: findComposer takes the footer box and ignores one outside #main', () => {
  const doc = chat();
  assert.equal(SITE.findComposer(doc).getAttribute('aria-label'), 'Type a message to Test Partner');
  assert.equal(SITE.findComposer(new JSDOM('<div contenteditable="true" role="textbox"></div>').window.document), null);
});

test('WhatsApp: the card goes inside the footer, before the composer row', () => {
  // Before the footer itself, WhatsApp's flex column put the card at the top of the chat (live check).
  const doc = chat();
  const box = SITE.findComposer(doc);
  const anchor = SITE.cardAnchor(box);
  assert.equal(anchor.parentElement.tagName, 'FOOTER');
  assert.ok(anchor.contains(box));
});

test('WhatsApp: no thread root until the title is there', () => {
  assert.equal(SITE.findThreadRoot(withTitle(null)), null);
  assert.equal(SITE.findThreadRoot(chat()).id, 'main');
});
