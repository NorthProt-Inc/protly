// Instagram as mounted by the content script: bracket notes in a DM draft (plan
// docs/plans/2026-11-08-notes-and-iphone-port.md, Part A). A draft with a note never goes out as typed, a draft of
// notes only runs nothing, a note typed into a shown translation is held, and Alt+Z brings the notes back. One mount
// for the whole file (see instagram-mount.js); every test starts and ends with the composer idle.
import { test, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mountInstagram } from './instagram-mount.js';
import { _trustSyntheticEvents } from '../src/ui/trust.js';
import { shadowOf } from '../src/ui/card.js';
import { flags } from '../src/lib/flags.js';

const NOTES_ONLY = 'Add the message too. [Brackets] are notes for protly.';
const NOTE_ON_TRANSLATION = 'Notes work on a new draft. Undo first, then add the note.';
const DRAFT = '내일 보자 [좀 더 정중하게]';
const SHOWN = 'See you tomorrow.';

const pending = []; // billed calls that have not been answered: { msg, resolve }
const { win, asked, composer } = await mountInstagram({
  outgoing: (msg) => new Promise((resolve) => pending.push({ msg, resolve })),
});
const doc = win.document;
// jsdom has no execCommand: insertText replaces a select-all, as Lexical does.
doc.execCommand = (cmd, ui, text) => {
  composer.textContent = doc.getSelection().toString() === composer.textContent ? text : composer.textContent + text;
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
const altZ = () => key({ key: 'z', code: 'KeyZ', altKey: true });
const card = () => doc.querySelector('.pl-card');
const cardPart = (cls) => { const h = card(); return h ? shadowOf(h).querySelector(cls)?.textContent : undefined; };
const billed = () => asked.filter((m) => m.type === 'outgoing' || m.type === 'polish');
const answer = (translation = SHOWN, lang = 'en') => {
  const p = pending.shift();
  assert.ok(p, 'a billed call is waiting');
  p.resolve({ ok: true, data: { translation, back_translation: '내일 봐요', lang, model: 'claude-sonnet-5-5' } });
};
const compose = (text) => { composer.textContent = text; composer.focus(); };

async function toPreview(draft = DRAFT, { translation = SHOWN, lang = 'en' } = {}) {
  compose(draft);
  assert.equal(enter().defaultPrevented, true);
  answer(translation, lang);
  await until(() => cardPart('.hints'));
  assert.equal(composer.textContent, translation);
}
// Back to idle with the raw draft in the box.
async function undo(draft = DRAFT) {
  assert.equal(altZ().defaultPrevented, true);
  await until(() => composer.textContent === draft);
  await wait(SETTLED);
  assert.equal(altZ().defaultPrevented, false);
}

beforeEach(async () => {
  _trustSyntheticEvents(true);
  flags.polish = false;
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await wait(SETTLED);
  for (let i = 0; i < 5 && altZ().defaultPrevented; i++) await wait(SETTLED);
  pending.splice(0).forEach((p) => p.resolve({ ok: false, error: { message: 'reset' } }));
  await wait(20);
  composer.textContent = '';
  asked.length = 0;
});

test('Enter on a Korean draft with a note sends the text and the notes; Alt+Z restores the draft with its note', async () => {
  await toPreview();
  const [m] = billed();
  assert.deepEqual([m.type, m.korean, m.notes], ['outgoing', '내일 보자', ['좀 더 정중하게']]);
  // Alt+Enter re-runs deep with the same notes.
  assert.equal(enter({ altKey: true }).defaultPrevented, true);
  await until(() => pending.length === 1);
  assert.deepEqual([billed()[1].profile, billed()[1].korean, billed()[1].notes], ['hard', '내일 보자', ['좀 더 정중하게']]);
  answer();
  await until(() => cardPart('.hints'));
  await undo();
});

test('Enter on an English draft with a note polishes it with the Polish switch off', async () => {
  compose('see you [formal]');
  assert.equal(enter().defaultPrevented, true);
  await until(() => pending.length === 1);
  const [m] = billed();
  assert.deepEqual([m.type, m.text, m.notes], ['polish', 'see you', ['formal']]);
  answer('See you.');
  await until(() => cardPart('.hints'));
  await undo('see you [formal]');
  // Control: without the note the same draft goes out as typed.
  compose('see you');
  assert.equal(enter().defaultPrevented, false);
  assert.equal(billed().length, 1);
});

test('a draft of notes only runs nothing and says why', async () => {
  compose('[formal] [short]');
  assert.equal(enter().defaultPrevented, true);
  await until(() => cardPart('.msg'));
  assert.equal(cardPart('.msg'), NOTES_ONLY);
  await wait(20);
  assert.deepEqual(billed(), []);
  assert.equal(composer.textContent, '[formal] [short]');
});

test('a note typed into a preview or a kept translation is held, and Undo still brings back the draft', async () => {
  await toPreview();
  composer.textContent = `${SHOWN} [shorter]`;
  assert.equal(enter().defaultPrevented, true);
  await until(() => cardPart('.msg') === NOTE_ON_TRANSLATION);
  assert.equal(billed().length, 1);
  assert.equal(asked.filter((m) => m.type === 'sent').length, 0);
  await undo();

  await toPreview();
  assert.equal(esc().defaultPrevented, true); // kept
  composer.textContent = `${SHOWN} [shorter]`;
  assert.equal(enter().defaultPrevented, true);
  await until(() => cardPart('.msg') === NOTE_ON_TRANSLATION);
  assert.equal(billed().length, 2);
  assert.equal(asked.filter((m) => m.type === 'sent').length, 0);
  await undo();
});

test('a page script Enter on an English draft with a note is held', async () => {
  compose('see you [formal]');
  _trustSyntheticEvents(false);
  assert.equal(enter().defaultPrevented, true);
  compose('see you');
  assert.equal(enter().defaultPrevented, false); // control: plain English with Polish off is the page's
  await wait(20);
  assert.deepEqual(billed(), []);
});

test('an IME Enter on a draft with a note is held and then runs it', async () => {
  compose('see you [formal]');
  composer.dispatchEvent(new win.Event('compositionstart', { bubbles: true }));
  assert.equal(enter({ isComposing: true }).defaultPrevented, true);
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await until(() => pending.length === 1);
  assert.deepEqual([billed()[0].type, billed()[0].notes], ['polish', ['formal']]);
  answer('See you.');
  await until(() => cardPart('.hints'));
  await undo('see you [formal]');
});

test('an IME Enter on a kept Korean translation with a note is held, and the note is refused', async () => {
  await toPreview(DRAFT, { translation: '내일 봐요', lang: 'ko' });
  assert.equal(esc().defaultPrevented, true);
  composer.textContent = '내일 봐요 [짧게]';
  composer.dispatchEvent(new win.Event('compositionstart', { bubbles: true }));
  assert.equal(enter({ isComposing: true }).defaultPrevented, true);
  composer.dispatchEvent(new win.Event('compositionend', { bubbles: true }));
  await until(() => cardPart('.msg') === NOTE_ON_TRANSLATION);
  assert.equal(billed().length, 1);
  await undo();
});

test('composer selector broken: the user Enter on a box with a note is held too', async () => {
  compose('see you [formal]');
  composer.removeAttribute('role'); // the selector no longer finds the composer
  Object.defineProperty(composer, 'isContentEditable', { value: true, configurable: true }); // jsdom has none
  try {
    assert.equal(enter().defaultPrevented, true);
    composer.textContent = 'see you';
    assert.equal(enter().defaultPrevented, false); // control: plain English is not protly's to hold
  } finally {
    composer.setAttribute('role', 'textbox');
    delete composer.isContentEditable;
  }
  await wait(20);
  assert.deepEqual(billed(), []);
});

// Last in the file: it switches the thread for a moment.
test('right after a thread switch, before the new handler mounts, an Enter on a draft with a note is held', async () => {
  compose('see you [formal]');
  Object.defineProperty(composer, 'isContentEditable', { value: true, configurable: true }); // jsdom has none
  win.history.pushState({}, '', '/direct/t/456/');
  try {
    assert.equal(enter().defaultPrevented, true);
    composer.textContent = 'see you';
    assert.equal(enter().defaultPrevented, false); // control: nothing to guard
  } finally {
    win.history.pushState({}, '', '/direct/t/123/');
    delete composer.isContentEditable;
  }
  assert.deepEqual(billed(), []);
});
