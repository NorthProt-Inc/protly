// Instagram as mounted by the content script: the edges of Esc (keep) and Alt+Z (undo), and what the kept mode does
// with Enter, IME composition and a thread switched off. One mount for the whole file (see instagram-mount.js); every
// test starts and ends with the composer idle.
import { test, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mountInstagram } from './instagram-mount.js';
import { _trustSyntheticEvents } from '../src/ui/trust.js';
import { shadowOf } from '../src/ui/card.js';
import { flags } from '../src/lib/flags.js';
import { getCurrent } from '../src/content/main.js';

const KOREAN = '지민아 또 봐';
const SHOWN = 'See you, 지민';

const pending = []; // billed calls that have not been answered: { msg, resolve }
const { win, asked, composer } = await mountInstagram({
  outgoing: (msg) => new Promise((resolve) => pending.push({ msg, resolve })),
});
const doc = win.document;
let onWrite = null; // called after each composer write
// jsdom has no execCommand: insertText replaces a select-all, as Lexical does.
doc.execCommand = (cmd, ui, text) => {
  composer.textContent = doc.getSelection().toString() === composer.textContent ? text : composer.textContent + text;
  onWrite?.(text);
  return true;
};
_trustSyntheticEvents(true);
after(() => _trustSyntheticEvents(false));

const until = async (f, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 2));
  }
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLED = 300; // well past a write (60 ms select settle) plus its 50 ms check

const key = (init, type = 'keydown') => {
  const e = new win.KeyboardEvent(type, { bubbles: true, cancelable: true, ...init });
  composer.dispatchEvent(e);
  return e;
};
const enter = (init = {}) => key({ key: 'Enter', code: 'Enter', ...init });
const esc = () => key({ key: 'Escape', code: 'Escape' });
const altZ = (init = {}) => key({ key: 'z', code: 'KeyZ', altKey: true, ...init });
const card = () => doc.querySelector('.pl-card');
const cardPart = (cls) => { const h = card(); return h ? shadowOf(h).querySelector(cls)?.textContent : undefined; };
const billed = () => asked.filter((m) => m.type === 'outgoing' || m.type === 'polish');
const sent = () => asked.filter((m) => m.type === 'sent').map(({ text, korean }) => ({ text, korean }));
const answer = (translation, lang = 'en') => {
  const p = pending.shift();
  assert.ok(p, 'a billed call is waiting');
  p.resolve({ ok: true, data: { translation, back_translation: KOREAN, lang, model: 'claude-sonnet-5-5' } });
};

async function toPreview({ translation = SHOWN, lang = 'en' } = {}) {
  composer.textContent = KOREAN;
  composer.focus();
  assert.equal(enter().defaultPrevented, true);
  answer(translation, lang);
  await until(() => cardPart('.hints'));
  assert.equal(composer.textContent, translation);
}
async function toKept(opts) {
  await toPreview(opts);
  assert.equal(esc().defaultPrevented, true);
  assert.equal(card(), null);
  assert.equal(composer.textContent, opts?.translation ?? SHOWN);
}
// Back to idle with the Korean draft in the box.
async function undo() {
  assert.equal(altZ().defaultPrevented, true);
  await until(() => composer.textContent === KOREAN);
  await wait(SETTLED);
  assert.equal(altZ().defaultPrevented, false);
}

// Back to idle whatever the previous test left, so one failure does not fail the rest.
beforeEach(async () => {
  _trustSyntheticEvents(true);
  flags.polish = false;
  onWrite = null;
  const cur = getCurrent();
  if (!cur.thread.enabled) cur.thread = { ...cur.thread, enabled: true };
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await wait(SETTLED);
  for (let i = 0; i < 5 && altZ().defaultPrevented; i++) await wait(SETTLED);
  pending.splice(0).forEach((p) => p.resolve({ ok: false, error: { message: 'reset' } }));
  await wait(20);
  composer.textContent = KOREAN;
});

test('Option+Z on a Mac (key Ω, code KeyZ) puts the Korean back', async () => {
  await toPreview();
  assert.equal(altZ({ key: 'Ω' }).defaultPrevented, true);
  await until(() => composer.textContent === KOREAN);
  assert.equal(card(), null);
  await wait(SETTLED);
  assert.equal(altZ({ key: 'Ω' }).defaultPrevented, false); // idle: the page's
});

test('Ctrl+Alt+Z (AltGr), Shift+Alt+Z and Cmd+Alt+Z are not Alt+Z', async () => {
  await toKept();
  for (const mod of [{ ctrlKey: true }, { shiftKey: true }, { metaKey: true }]) {
    assert.equal(altZ(mod).defaultPrevented, false, JSON.stringify(mod));
  }
  await wait(SETTLED);
  assert.equal(composer.textContent, SHOWN);
  await undo(); // still kept: the plain key restores
});

test('a page script cannot keep or undo: an untrusted Esc or Alt+Z does nothing', async () => {
  await toPreview();
  _trustSyntheticEvents(false);
  try {
    assert.equal(esc().defaultPrevented, false);
    assert.equal(altZ().defaultPrevented, false);
  } finally {
    _trustSyntheticEvents(true);
  }
  await wait(SETTLED);
  assert.equal(composer.textContent, SHOWN);
  assert.ok(cardPart('.hints')); // still the preview
  await undo();
});

test('Alt+Z while the written translation is being checked is held and changes nothing', async () => {
  const before = billed().length;
  let held = null;
  // Right after the translation lands in the box: the write is done, its check has not run yet.
  onWrite = (text) => { if (text === SHOWN) setImmediate(() => { held = altZ().defaultPrevented; }); };
  try {
    await toPreview();
  } finally {
    onWrite = null;
  }
  assert.equal(held, true);
  assert.equal(billed().length, before + 1);
  await wait(SETTLED);
  assert.equal(composer.textContent, SHOWN);
  assert.ok(cardPart('.hints'));
  await undo();
});

test('Alt+Z mid-composition is left to the IME, in kept too', async () => {
  await toKept();
  assert.equal(altZ({ isComposing: true }).defaultPrevented, false);
  composer.dispatchEvent(new win.Event('compositionstart', { bubbles: true }));
  assert.equal(altZ().defaultPrevented, false); // the composition flag, for browsers that do not set isComposing
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await wait(SETTLED);
  assert.equal(composer.textContent, SHOWN);
  await undo();
});

test('Esc during a first request keeps the draft, closes the card, and the late translation never lands', async () => {
  composer.textContent = KOREAN;
  assert.equal(enter().defaultPrevented, true);
  assert.equal(cardPart('.msg'), 'Translating');
  assert.equal(esc().defaultPrevented, true);
  assert.equal(card(), null);
  answer(SHOWN);
  await wait(SETTLED);
  assert.equal(composer.textContent, KOREAN);
  assert.equal(card(), null);
  // Idle again: the next Enter is a new request.
  const before = billed().length;
  assert.equal(enter().defaultPrevented, true);
  assert.equal(billed().length, before + 1);
  assert.equal(altZ().defaultPrevented, true);
  answer(SHOWN); // dropped too
  await wait(SETTLED);
  assert.equal(composer.textContent, KOREAN);
});

test('Alt+Enter re-runs deep: the card says Translating deeply, then marks the result deep', async () => {
  await toPreview();
  assert.equal(cardPart('.model'), 'Sonnet'); // a first run: no 'deep'
  assert.equal(cardPart('.hints'), 'Enter send · Esc keep · Alt+Z undo · Alt+Enter deep');
  assert.equal(enter({ altKey: true }).defaultPrevented, true);
  assert.equal(billed().at(-1).profile, 'hard');
  assert.match(cardPart('.msg'), /^Translating deeply/);
  answer('see you then, 지민');
  await until(() => cardPart('.model') === 'Sonnet deep');
  await undo();
});

test('Esc during a deep re-run keeps the first translation, and Enter records it with the Korean draft', async () => {
  await toPreview();
  assert.equal(enter({ altKey: true }).defaultPrevented, true);
  assert.equal(billed().at(-1).profile, 'hard');
  assert.equal(esc().defaultPrevented, true);
  assert.equal(card(), null);
  answer('Opus: see you, 지민');
  await wait(SETTLED);
  assert.equal(composer.textContent, SHOWN);
  const n = sent().length;
  assert.equal(enter().defaultPrevented, false); // Instagram sends it
  assert.deepEqual(sent().slice(n), [{ text: SHOWN, korean: KOREAN }]);
  composer.textContent = KOREAN; // Instagram empties the box; the next test types again
});

test('kept: Enter sends an English edit unpolished with Polish on; new Hangul bills one translation of it all', async () => {
  flags.polish = true;
  try {
    await toKept();
    const before = billed().length;
    composer.textContent = 'See you soon, 지민';
    assert.equal(enter().defaultPrevented, false);
    assert.equal(billed().length, before);
    assert.deepEqual(sent().at(-1), { text: 'See you soon, 지민', korean: KOREAN });

    await toKept();
    const n = billed().length;
    composer.textContent = `${SHOWN} 빨리 와`;
    assert.equal(enter().defaultPrevented, true);
    assert.deepEqual(billed().slice(n).map((m) => [m.type, m.korean, m.profile]), [['outgoing', `${SHOWN} 빨리 와`, 'outgoing']]);
    assert.equal(enter().defaultPrevented, true); // in flight: held, not billed again
    assert.equal(billed().length, n + 1);
    assert.equal(altZ().defaultPrevented, true);
    answer('dropped');
    await until(() => composer.textContent === `${SHOWN} 빨리 와`); // its source, not the first draft
    await wait(SETTLED);
    composer.textContent = KOREAN;
  } finally {
    flags.polish = false;
  }
});

test('kept: turning translation off for the thread drops the kept translation', async () => {
  await toKept();
  const cur = getCurrent();
  cur.thread = { ...cur.thread, enabled: false };
  cur.onThreadUpdate.forEach((f) => f(cur.thread));
  cur.thread = { ...cur.thread, enabled: true };
  cur.onThreadUpdate.forEach((f) => f(cur.thread));
  const n = sent().length;
  composer.textContent = 'See you soon';
  assert.equal(enter().defaultPrevented, false);
  assert.equal(sent().length, n); // an ordinary send now, not a kept one
  composer.textContent = KOREAN;
});

test('kept: an IME Enter passes with a Korean target, and is held then asks for another Enter otherwise', async () => {
  await toKept({ translation: '지민아 또 봐요', lang: 'ko' });
  composer.dispatchEvent(new win.Event('compositionstart', { bubbles: true }));
  assert.equal(enter({ isComposing: true }).defaultPrevented, false);
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await wait(20);
  assert.equal(card(), null);
  await undo();

  await toKept();
  const n = sent().length;
  composer.dispatchEvent(new win.Event('compositionstart', { bubbles: true }));
  assert.equal(enter({ isComposing: true }).defaultPrevented, true); // the box holds Hangul (the name)
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await until(() => cardPart('.msg') === 'Press Enter again to send.');
  assert.equal(sent().length, n); // the blocked Enter sent nothing, so nothing is recorded
  await undo(); // still kept
});
