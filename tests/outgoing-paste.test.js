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
