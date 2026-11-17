// Instagram as mounted by the content script, with a Lexical-like composer (fake-editors.js): a multi-line
// translation is pasted, never inserted with insertText, and every restore pastes the Korean back line for line
// (fix track C2). One mount for the file; each test gives it a fresh composer and ends idle.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mountInstagram } from './instagram-mount.js';
import { _trustSyntheticEvents } from '../src/ui/trust.js';
import { shadowOf } from '../src/ui/card.js';
import { fakeEditor, nonblank } from './fake-editors.js';

const KO = ['가나다', '라마바', '사아자'];
const EN = 'A1\nB2\nC3';
const TYPED = '<p><span>가나다</span><br><span>라마바</span><br><span>사아자</span></p>'; // Shift+Enter between lines
const TRAILING = '<p><span>가나다</span><br><span>라마바</span><br><span>사아자</span><br><br></p>'; // and after the last

const pending = [];
const { win, composer: first } = await mountInstagram({
  outgoing: (msg) => new Promise((resolve) => pending.push({ msg, resolve })),
});
const doc = win.document;
_trustSyntheticEvents(true);
after(() => _trustSyntheticEvents(false));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (f, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error('timed out');
    await sleep(2);
  }
};
const SETTLED = 300;

let composer = first;
// A fresh Lexical-like composer in place of the last one, holding html.
function freshComposer(html, fake = {}) {
  const c = doc.createElement('div');
  c.setAttribute('role', 'textbox');
  c.setAttribute('contenteditable', 'true');
  c.tabIndex = 0;
  composer.replaceWith(c);
  composer = c;
  const log = fakeEditor(c, { kind: 'lexical', ...fake });
  c.innerHTML = html;
  c.focus();
  return log;
}
const key = (init) => {
  const e = new win.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init });
  composer.dispatchEvent(e);
  return e;
};
const enter = () => key({ key: 'Enter', code: 'Enter' });
const altZ = () => key({ key: 'z', code: 'KeyZ', altKey: true });
const cardPart = (cls) => { const h = doc.querySelector('.pl-card'); return h ? shadowOf(h).querySelector(cls)?.textContent : undefined; };
const answer = (translation) => {
  const p = pending.shift();
  assert.ok(p, 'a billed call is waiting');
  p.resolve({ ok: true, data: { translation, back_translation: '역번역', lang: 'en', model: 'claude-sonnet-5-5' } });
};
const FAILED = 'Could not write the translation into the message box. Nothing was sent.';

test('a multi-line translation is pasted, every line lands, and Alt+Z pastes the Korean back line for line', async () => {
  const log = freshComposer(TYPED);
  assert.equal(enter().defaultPrevented, true);
  await until(() => pending.length === 1);
  answer(EN);
  await until(() => cardPart('.hints'));
  assert.deepEqual(nonblank(composer.innerText), ['A1', 'B2', 'C3']);
  assert.equal(altZ().defaultPrevented, true);
  await until(() => log.pastes.length === 2);
  await sleep(SETTLED);
  assert.deepEqual(log.pastes, [EN, KO.join('\n')]);
  assert.deepEqual(log.inserts, []);
  assert.deepEqual(nonblank(composer.innerText), KO);
});

test('rich Lexical: Enter and Alt+Z, three times over, send and restore the same two lines, no blank line gained', async () => {
  // A paste makes one <p> per line, and Chrome's innerText puts a blank line between <p>s: a draft read that way grew
  // by a blank line on every cycle (review of C2). The composer read counts one line break between blocks.
  const log = freshComposer('<p>가나다<br>라마바</p>');
  const sent = [];
  for (let round = 0; round < 3; round++) {
    assert.equal(enter().defaultPrevented, true);
    await until(() => pending.length === 1);
    sent.push(pending[0].msg.korean);
    answer('A1\nB2');
    await until(() => cardPart('.hints'));
    assert.equal(composer.innerHTML, '<p>A1</p><p>B2</p>');
    assert.equal(altZ().defaultPrevented, true);
    await until(() => log.pastes.length === 2 * (round + 1));
    await sleep(SETTLED);
    assert.equal(composer.innerHTML, '<p>가나다</p><p>라마바</p>', `round ${round + 1}`);
  }
  assert.deepEqual(sent, ['가나다\n라마바', '가나다\n라마바', '가나다\n라마바']);
  assert.deepEqual(log.pastes, ['A1\nB2', '가나다\n라마바', 'A1\nB2', '가나다\n라마바', 'A1\nB2', '가나다\n라마바']);
  assert.deepEqual(log.inserts, []);
});

test('Alt+Z when the restore is refused: the card says so and the box keeps what it holds', async () => {
  const log = freshComposer(TYPED);
  assert.equal(enter().defaultPrevented, true);
  await until(() => pending.length === 1);
  answer(EN);
  await until(() => cardPart('.hints'));
  // As plain-text Lexical shows the translation, plus a Shift+Enter after it: a write would be cut short.
  const EDITED = '<p><span>A1</span><br><span>B2</span><br><span>C3</span><br><br></p>';
  composer.innerHTML = EDITED;
  assert.equal(altZ().defaultPrevented, true);
  await until(() => /Could not restore/.test(cardPart('.msg') || ''));
  await sleep(SETTLED);
  assert.equal(cardPart('.msg'), 'Could not restore the draft. Ctrl+Z may bring it back.');
  assert.deepEqual(log.pastes, [EN]);
  assert.equal(composer.innerHTML, EDITED);
});

test('a write that fails its check: the Korean is pasted back line for line and the failure is shown', async () => {
  const log = freshComposer(TYPED, { paste: (t) => (t === EN ? 'A1' : t) }); // the translation lands short
  assert.equal(enter().defaultPrevented, true);
  await until(() => pending.length === 1);
  answer(EN);
  await until(() => cardPart('.msg') === FAILED);
  await sleep(SETTLED);
  assert.deepEqual(log.pastes, [EN, KO.join('\n')]);
  assert.deepEqual(log.inserts, []);
  assert.deepEqual(nonblank(composer.innerText), KO);
});

test('a draft whose lines end in a line break is refused before any request, with what to do', async () => {
  const log = freshComposer(TRAILING);
  assert.equal(enter().defaultPrevented, true);
  await until(() => /empty line/.test(cardPart('.msg') || ''));
  await sleep(SETTLED);
  assert.equal(cardPart('.msg'), 'Translation failed: Delete the empty line at the end of the message, then try again.');
  assert.equal(pending.length, 0); // nothing billed
  assert.deepEqual(log.pastes, []);
  assert.deepEqual(log.inserts, []);
  assert.equal(composer.innerHTML, TRAILING);
});

test('a line break added at the end during the request is refused at the write: the draft as it was, the failure shown', async () => {
  const log = freshComposer(TYPED);
  assert.equal(enter().defaultPrevented, true);
  await until(() => pending.length === 1);
  composer.innerHTML = TRAILING; // Shift+Enter while translating: the same text by norm(), so the result is not dropped
  answer(EN);
  await until(() => cardPart('.msg') === FAILED);
  await sleep(SETTLED);
  assert.deepEqual(log.pastes, []);
  assert.deepEqual(log.inserts, []);
  assert.equal(composer.innerHTML, TRAILING);
});
