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
// A line ending in an inline decorator: Lexical adds its caret <br> after it.
const DECORATOR = '<p><span>가나다</span><span data-lexical-decorator="true" contenteditable="false">@민지</span><br></p>';

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

test('a Lexical draft the paste would cut short is refused before writing and left as it is', async () => {
  // Lexical ends its select-all after the last block's first inline node when that block ends in a <br> (a line
  // break, or the caret <br> after an inline decorator), so these are written only in part.
  for (const html of [
    TRAILING,
    '<p><span>안녕 </span><strong>친구</strong><br><br></p>', // two inline nodes on one line, then Shift+Enter
    '<p><span>가나다</span><span data-lexical-decorator="true" contenteditable="false">@민지</span><br></p>', // inline decorator last
    '<ul><li value="1"><span>가나다</span></li><li value="2"><span>라마바</span><br><span>사아자</span><br><br></li></ul>', // a list
  ]) {
    const { d, el } = page();
    const log = fakeEditor(el, { kind: 'lexical' });
    el.innerHTML = html;
    el.focus();
    assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), false, html);
    assert.equal(await setComposerText(el, EN), false, html);
    assert.deepEqual(log.pastes, [], html);
    assert.deepEqual(log.inserts, [], html);
    assert.equal(el.innerHTML, html);
  }
});

test('Lexical drafts that a paste replaces whole are written, lists too', async () => {
  for (const html of [
    '<p><span>가나다</span><br><br></p>', // one line, then Shift+Enter
    '<p><span>가나다</span></p><p><span>라마바</span></p><p><span>사아자</span><br><br></p>', // the last paragraph is one line
    '<p><span>가나다</span></p><p><span>라마바</span></p><p><br></p>', // rich text, Enter onto an empty last line
    '<p><span data-lexical-decorator="true" contenteditable="false">@민지</span><br></p>', // an inline decorator alone, then its caret <br>
    '<ul><li><span>가나다</span></li><li><span>라마바</span><br><br></li></ul>', // a list whose last item is one line, then Shift+Enter
    '<ul><li><span>가나다</span></li><li><span>라마바</span></li></ul>', // a list whose last item is plain text
  ]) {
    const { d, el } = page();
    const log = fakeEditor(el, { kind: 'lexical' });
    el.innerHTML = html;
    el.focus();
    assert.equal(await writeBox(box(d, el), EN, { settleMs: 0 }), true, html);
    assert.deepEqual(log.pastes, [EN], html);
    assert.deepEqual(log.inserts, [], html);
    const fresh = page(); // the composer path too
    fakeEditor(fresh.el, { kind: 'lexical' });
    fresh.el.innerHTML = html;
    assert.equal(await setComposerText(fresh.el, EN), true, html);
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
  const asked = [];
  const ask = (m) => { asked.push(m); return new Promise((res) => pending.push(res)); };
  const inst = createInstance({ doc, ask, fonts: null });
  const root = () => { const h = doc.querySelector('.pl-card'); return h ? shadowOf(h) : undefined; };
  const msg = () => root()?.querySelector('.msg')?.textContent ?? null;
  const btn = (label) => [...(root()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  const toasts = () => doc.querySelector('.pl-toasts')?.shadowRoot?.textContent ?? '';
  const reply = (translation) => pending.shift()({ translation, back_translation: '역번역', model: 'claude-sonnet-5-5', lang: 'en' });
  return { doc, el, log, pending, asked, inst, msg, btn, toasts, reply };
}
const SETTLED = 300;
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

test('generic, Lexical: a draft the write would cut short is refused before any request, saying what to do', async () => {
  for (const [html, what, not] of [
    [TRAILING, 'Delete the empty line at the end of the message, then try again.', /Type a space/],
    [DECORATOR, 'Type a space at the end of the message, then try again.', /empty line/], // Lexical's caret <br>
  ]) {
    const s = generic({ kind: 'lexical' });
    s.el.innerHTML = html;
    s.el.focus();
    s.inst.run({ source: 'command' });
    await until(() => s.toasts().includes(what));
    await sleep(SETTLED);
    assert.doesNotMatch(s.toasts(), not);
    assert.equal(s.asked.length, 0); // nothing billed
    assert.equal(s.msg(), null);
    assert.deepEqual(s.log.pastes, []);
    assert.deepEqual(s.log.inserts, []);
    assert.equal(s.el.innerHTML, html);
  }
});

test('generic, Lexical: a line break added at the end during the request is refused at the write, untouched', async () => {
  const s = generic({ kind: 'lexical' });
  s.el.innerHTML = TYPED;
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.el.innerHTML = TRAILING; // Shift+Enter while translating: the same text by norm(), so the result is not dropped
  s.reply(EN);
  await until(() => /Could not write/.test(s.msg() || ''));
  assert.equal(s.msg(), 'Could not write into this box. Nothing was changed.');
  assert.deepEqual(s.log.pastes, []);
  assert.deepEqual(s.log.inserts, []);
  assert.equal(s.el.innerHTML, TRAILING);
});

test('generic, Lexical: a re-run on a shown translation the write would cut short is refused on the card, no call', async () => {
  // Plain-text Lexical, one line and a Shift+Enter: written whole, but the paste keeps the line break, so the shown
  // translation is the cut-short shape. Deep, the language chip, Alt+T and Replace anyway all re-run through request().
  const SHOWN = '<p><span>A1</span><br><span>B2</span><br><span>C3</span><br><br></p>';
  const s = generic({ kind: 'lexical', paste: (t) => { if (t !== EN) return t; s.el.innerHTML = SHOWN; return undefined; } });
  s.el.innerHTML = '<p><span>가나다</span><br><br></p>';
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.reply(EN);
  await until(() => s.btn('Deep'));
  s.btn('Deep').click();
  await until(() => /empty line/.test(s.msg() || ''));
  await sleep(SETTLED);
  assert.equal(s.msg(), 'Delete the empty line at the end of the message, then try again.');
  assert.equal(s.asked.length, 1); // no second billed call
  assert.ok(s.btn('Undo')); // still the preview's way back
  assert.equal(s.el.innerHTML, SHOWN);
});

test('generic, Lexical: Esc during the check, then a refused roll-back: a toast says so, nothing more is written', async () => {
  // The translation renders late, as plain-text Lexical with a line break after it: the roll-back is refused.
  const LATE = '<p><span>A1</span><br><span>B2</span><br><span>C3</span><br><br></p>';
  const s = generic({ kind: 'lexical', paste: () => { setTimeout(() => { s.el.innerHTML = LATE; }, 80); } });
  s.el.innerHTML = TYPED;
  s.el.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.pending.length === 1);
  s.reply(EN);
  await until(() => s.log.pastes.length === 1); // written, not yet rendered
  s.el.dispatchEvent(new s.doc.defaultView.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true, composed: true }));
  await sleep(SETTLED + 200);
  assert.match(s.toasts(), /Could not restore the original text\. Ctrl\+Z may bring it back\./);
  assert.deepEqual(s.log.pastes, [EN]);
  assert.equal(s.el.innerHTML, LATE);
});
