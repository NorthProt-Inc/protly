// Multi-line writes into Lexical, Draft.js and Slate (fix track C2): those three are written with a synthetic
// text/plain paste, found by their DOM marker; every other box keeps execCommand('insertText'). Fake editors in
// fake-editors.js behave as the Chromium harness found the real ones.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { setComposerText } from '../src/content/dom.js';
import { readBox, writeBox } from '../src/generic/writer.js';
import { createInstance } from '../src/generic/instance.js';
import { shadowOf } from '../src/ui/card.js';
import { _resetToasts } from '../src/ui/toast.js';
import { fakeEditor, nonblank, setLines } from './fake-editors.js';

const KO = ['가나다', '라마바', '사아자'];
const EN = 'A1\nB2\nC3';
// Lexical after Shift+Enter between the lines and after the last one: the line break plus Lexical's caret <br>.
const TRAILING = '<p><span>가나다</span><br><span>라마바</span><br><span>사아자</span><br><br></p>';

function page() {
  const d = new JSDOM('<body><div id="b" contenteditable="true" tabindex="0"></div><input id="o"></body>').window.document;
  return { d, el: d.getElementById('b') };
}
const box = (d, el) => ({ el, doc: d, kind: 'contenteditable' });

for (const kind of ['lexical', 'draft', 'slate']) {
  test(`${kind}: the generic writer pastes the whole text once, with no insertText, and every line lands`, async () => {
    const { d, el } = page();
    const log = fakeEditor(el, { kind });
    setLines(el, KO);
    el.focus();
    assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), true);
    assert.deepEqual(log.pastes, [EN]);
    assert.deepEqual(log.inserts, []);
    assert.equal(readBox(box(d, el)), EN);
  });
}

test('Lexical composer: setComposerText pastes the whole text, with no insertText, and every line lands', async () => {
  const { el } = page();
  const log = fakeEditor(el, { kind: 'lexical' });
  setLines(el, KO);
  assert.equal(await setComposerText(el, EN), true);
  assert.deepEqual(log.pastes, [EN]);
  assert.deepEqual(log.inserts, []);
  assert.deepEqual(nonblank(el.innerText), ['A1', 'B2', 'C3']);
});

test('a contenteditable without a marker keeps insertText, even one with its own paste handler', async () => {
  const { d, el } = page();
  const log = fakeEditor(el, { kind: null }); // Quill-like: a paste would be handled without preventDefault
  setLines(el, KO);
  el.focus();
  assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), true);
  assert.equal(await setComposerText(el, 'X1\nY2'), true);
  assert.deepEqual(log.pastes, []);
  assert.deepEqual(log.inserts, [EN, 'X1\nY2']);
});

test('a marked editor that ignores the paste: no insertText after it, and the generic write reports false', async () => {
  const { d, el } = page();
  const log = fakeEditor(el, { kind: 'lexical', paste: null });
  setLines(el, KO);
  el.focus();
  assert.equal(await writeBox(box(d, el), EN, { settleMs: 0, verifyMs: 30 }), false);
  await setComposerText(el, EN); // the composer's caller checks the box itself
  assert.deepEqual(log.pastes, [EN, EN]);
  assert.deepEqual(log.inserts, []);
  assert.deepEqual(nonblank(el.innerText), KO);
});

test('a Lexical draft whose lines end in a line break is refused before writing and left as it is', async () => {
  const { d, el } = page();
  const log = fakeEditor(el, { kind: 'lexical' });
  el.innerHTML = TRAILING;
  el.focus();
  assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), false);
  assert.equal(await setComposerText(el, EN), false);
  assert.deepEqual(log.pastes, []);
  assert.deepEqual(log.inserts, []);
  assert.equal(el.innerHTML, TRAILING);
});

test('Lexical drafts ending in a line break that a paste replaces whole are written', async () => {
  for (const html of [
    '<p><span>가나다</span><br><br></p>', // one line, then Shift+Enter
    '<p><span>가나다</span></p><p><span>라마바</span></p><p><span>사아자</span><br><br></p>', // the last paragraph is one line
    '<p><span>가나다</span></p><p><span>라마바</span></p><p><br></p>', // rich text, Enter onto an empty last line
  ]) {
    const { d, el } = page();
    const log = fakeEditor(el, { kind: 'lexical' });
    el.innerHTML = html;
    el.focus();
    assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), true, html);
    assert.deepEqual(log.pastes, [EN], html);
    assert.deepEqual(log.inserts, [], html);
  }
});

// ---- the generic instance (Alt+T on any site): write, check, restore ----

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 2000) {
  const end = Date.now() + ms;
  while (!fn()) { if (Date.now() > end) throw new Error('timed out'); await sleep(5); }
}

function generic(fake) {
  _resetToasts();
  const dom = new JSDOM('<body><div id="b" contenteditable="true" tabindex="0"></div></body>', { url: 'https://forum.example.org/post' });
  const doc = dom.window.document;
  const el = doc.getElementById('b');
  const log = fakeEditor(el, fake);
  const pending = [];
  const inst = createInstance({ doc, ask: () => new Promise((res) => pending.push(res)), fonts: null });
  const root = () => { const h = doc.querySelector('.pl-card'); return h ? shadowOf(h) : undefined; };
  const msg = () => root()?.querySelector('.msg')?.textContent ?? null;
  const btn = (label) => [...(root()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  const reply = (translation) => pending.shift()({ translation, back_translation: '역번역', model: 'claude-sonnet-5-5', lang: 'en' });
  return { doc, el, log, pending, inst, msg, btn, reply };
}
// A Lexical draft typed with Shift+Enter between the lines.
const TYPED = '<p><span>가나다</span><br><span>라마바</span><br><span>사아자</span></p>';

test('generic, Lexical: the translation is pasted, and Undo pastes the original back line for line', async () => {
  const s = generic({ kind: 'lexical' });
  s.el.innerHTML = TYPED;
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.reply(EN);
  await until(() => s.btn('Undo'));
  assert.equal(readBox({ el: s.el, doc: s.doc, kind: 'contenteditable' }), EN);
  s.btn('Undo').click();
  await until(() => s.log.pastes.length === 2);
  await sleep(20);
  assert.deepEqual(s.log.pastes, [EN, KO.join('\n')]);
  assert.deepEqual(s.log.inserts, []);
  assert.deepEqual(nonblank(s.el.innerText), KO);
});

test('generic, Lexical: a write that fails its check is restored by the same paste, line for line', async () => {
  const s = generic({ kind: 'lexical', paste: (t) => (t === EN ? 'A1' : t) }); // the translation lands short
  s.el.innerHTML = TYPED;
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.reply(EN);
  await until(() => /Could not write/.test(s.msg() || ''));
  assert.equal(s.msg(), 'Could not write into this box. Nothing was changed.');
  assert.deepEqual(s.log.pastes, [EN, KO.join('\n')]);
  assert.deepEqual(s.log.inserts, []);
  assert.deepEqual(nonblank(s.el.innerText), KO);
});

test('generic, Lexical: a draft whose lines end in a line break is refused with the failure message, untouched', async () => {
  const s = generic({ kind: 'lexical' });
  s.el.innerHTML = TRAILING;
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.reply(EN);
  await until(() => /Could not write/.test(s.msg() || ''));
  assert.equal(s.msg(), 'Could not write into this box. Nothing was changed.');
  assert.deepEqual(s.log.pastes, []);
  assert.deepEqual(s.log.inserts, []);
  assert.equal(s.el.innerHTML, TRAILING);
});
