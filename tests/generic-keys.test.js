// Alt+T on any site: Esc keeps what the box holds and closes the card, Alt+Z puts the original back (or, while a
// request is in flight, cancels it).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { createInstance } from '../src/generic/instance.js';
import { shadowOf } from '../src/ui/card.js';
import { _resetToasts } from '../src/ui/toast.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 1500) {
  const end = Date.now() + ms;
  while (!fn()) { if (Date.now() > end) throw new Error('timed out'); await sleep(5); }
}
const reply = (translation, back = '역번역', model = 'claude-sonnet-5-5', lang = 'en') =>
  ({ translation, back_translation: back, model, lang });

function setup(html = '<textarea id="b"></textarea><input id="o">') {
  _resetToasts();
  const dom = new JSDOM(`<body>${html}</body>`, { url: 'https://forum.example.org/post' });
  const doc = dom.window.document;
  const calls = [];
  const pending = [];
  const ask = (msg) => { calls.push(msg); return new Promise((res, rej) => pending.push({ res, rej })); };
  const inst = createInstance({ doc, ask, fonts: null });
  const host = () => doc.querySelector('.pl-card');
  const root = () => { const h = host(); return h ? shadowOf(h) : undefined; };
  const msg = () => root()?.querySelector('.msg')?.textContent ?? null;
  const btn = (label) => [...(root()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  const box = doc.getElementById('b');
  const val = () => (box.tagName === 'TEXTAREA' ? box.value : box.textContent);
  // keydown on el (default: the box); returns the event so callers can read defaultPrevented
  const key = (init, el = box) => {
    const e = new dom.window.KeyboardEvent('keydown', { bubbles: true, cancelable: true, composed: true, ...init });
    el.dispatchEvent(e);
    return e;
  };
  const ESC = { key: 'Escape', code: 'Escape' };
  const ALT_Z = { key: 'z', code: 'KeyZ', altKey: true };
  return { dom, doc, calls, pending, inst, host, root, msg, btn, box, val, key, ESC, ALT_Z };
}

// Translate '내일 봐' to 'see you tomorrow' and wait for the preview.
async function toPreview(s) {
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow', '내일 봐'));
  await until(() => s.btn('Undo'));
}

test('the preview card hints Esc keep and Alt+Z undo', async () => {
  const s = setup();
  await toPreview(s);
  assert.equal(s.root().querySelector('.hints')?.textContent, 'Esc keep · Alt+Z undo');
});

test('Esc while the first request is in flight: the box keeps the draft, the late result never lands', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  assert.match(s.msg(), /Translating/);
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.root(), undefined);
  s.pending[0].res(reply('see you tomorrow'));
  await sleep(50);
  assert.equal(s.box.value, '내일 봐');
  assert.equal(s.root(), undefined);
});

test('Esc during a re-run from the preview keeps the previous translation and closes the card', async () => {
  const s = setup();
  await toPreview(s);
  s.inst.run({ source: 'command' }); // Alt+T again: Opus
  await until(() => s.calls.length === 2);
  assert.match(s.msg(), /deeply/);
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.root(), undefined); // closed, not back to the old preview
  s.pending[1].res(reply('see you tomorrow then', '내일 봐', 'claude-opus-5-5'));
  await sleep(50);
  assert.equal(s.box.value, 'see you tomorrow');
  assert.equal(s.root(), undefined);
});

test('Alt+Z while the first request is in flight: closes, the box keeps the draft, the late result never lands', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  assert.equal(s.root(), undefined);
  s.pending[0].res(reply('see you tomorrow'));
  await sleep(50);
  assert.equal(s.box.value, '내일 봐');
  assert.equal(s.root(), undefined);
});

test('Alt+Z during a re-run returns to the preview; a second Alt+Z, after an edit, restores the original', async () => {
  const s = setup();
  await toPreview(s);
  s.btn('Deep').click();
  await until(() => s.calls.length === 2);
  assert.equal(s.btn('Undo'), undefined); // working
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  assert.ok(s.btn('Undo')); // the previous preview is back
  assert.equal(s.msg(), '내일 봐');
  s.pending[1].res(reply('see you tomorrow then', '내일 봐', 'claude-opus-5-5'));
  await sleep(50);
  assert.equal(s.box.value, 'see you tomorrow'); // the cancelled result was dropped
  s.box.value = 'see you tomorrow!!'; // the user edits the translation
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  await until(() => s.box.value === '내일 봐');
  assert.equal(s.root(), undefined);
});

test('Esc and Alt+Z inside an open IME composition are left to the page', async () => {
  const s = setup();
  await toPreview(s);
  assert.equal(s.key({ ...s.ESC, isComposing: true }).defaultPrevented, false);
  assert.equal(s.key({ ...s.ALT_Z, isComposing: true }).defaultPrevented, false);
  await sleep(20);
  assert.ok(s.btn('Undo'));
  assert.equal(s.box.value, 'see you tomorrow');
});

test('Esc and Alt+Z from outside the box are not swallowed and leave the preview', async () => {
  const s = setup();
  await toPreview(s);
  const other = s.doc.getElementById('o'); // not focused: no focusin closes the preview
  assert.equal(s.key(s.ALT_Z, other).defaultPrevented, false);
  assert.equal(s.key(s.ESC, other).defaultPrevented, false);
  await sleep(20);
  assert.ok(s.btn('Undo'));
  assert.equal(s.box.value, 'see you tomorrow');
});

test('Alt+Z with an extra modifier in the box is left to the page', async () => {
  const s = setup();
  await toPreview(s);
  for (const extra of [{ ctrlKey: true }, { shiftKey: true }, { metaKey: true }]) {
    assert.equal(s.key({ ...s.ALT_Z, ...extra }).defaultPrevented, false, JSON.stringify(extra));
  }
  await sleep(20);
  assert.ok(s.btn('Undo'));
  assert.equal(s.box.value, 'see you tomorrow');
});

test('Esc in the card itself (the Cancel button) keeps the draft and closes', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  assert.equal(s.key(s.ESC, s.btn('Cancel')).defaultPrevented, true);
  assert.equal(s.root(), undefined);
  s.pending[0].res(reply('see you tomorrow'));
  await sleep(50);
  assert.equal(s.box.value, '내일 봐');
});

test('a handled Esc never reaches the page own key handlers', async () => {
  const s = setup();
  await toPreview(s);
  let pageSaw = 0;
  s.box.addEventListener('keydown', () => { pageSaw++; }); // e.g. a site that closes its modal on Esc
  s.doc.addEventListener('keydown', () => { pageSaw++; }, true);
  s.key(s.ESC);
  assert.equal(pageSaw, 0);
  assert.equal(s.root(), undefined);
});

test('selection popover: Esc hides it and still reaches the page; Alt+Z leaves it open', async () => {
  const s = setup('<p>text</p>');
  s.inst.run({ source: 'menu-selection', selectionText: 'see you' });
  await until(() => s.calls.length === 1);
  s.pending[0].res({ src_lang: 'en', translation: '또 봐' });
  await until(() => s.msg() === '또 봐');
  const body = s.doc.body;
  assert.equal(s.key(s.ALT_Z, body).defaultPrevented, false);
  assert.equal(s.msg(), '또 봐');
  let pageSaw = 0;
  body.addEventListener('keydown', () => { pageSaw++; });
  assert.equal(s.key(s.ESC, body).defaultPrevented, false);
  assert.equal(pageSaw, 1);
  assert.equal(s.root(), undefined);
});

// A contenteditable box whose execCommand stub renders the insert after delayMs.
function editable(s, delayMs) {
  const writes = [];
  s.doc.execCommand = (cmd, ui, text) => {
    writes.push(text);
    setTimeout(() => { s.box.textContent = text; }, delayMs);
    return true;
  };
  return writes;
}
const CE = '<div id="b" contenteditable="true" tabindex="0"></div><input id="o">';

test('contenteditable: Esc while the written translation is being verified rolls the box back to the draft', async () => {
  const s = setup(CE);
  const writes = editable(s, 80);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => writes.length === 1); // past the select settle, the editor has not rendered yet
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.root(), undefined);
  await until(() => writes.length === 2);
  assert.equal(writes[1], '내일 봐');
  await until(() => s.box.textContent === '내일 봐');
  await sleep(150);
  assert.equal(s.box.textContent, '내일 봐');
  assert.equal(s.root(), undefined);
});

test('contenteditable: Alt+Z in the preview, after an edit, restores the original', async () => {
  const s = setup(CE);
  const writes = editable(s, 0);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  s.box.textContent = 'see you tomorrow!!';
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  await until(() => s.box.textContent === '내일 봐');
  assert.deepEqual(writes, ['see you tomorrow', '내일 봐']);
  assert.equal(s.root(), undefined);
});

test('contenteditable: Alt+Z during the select settle of a re-run writes nothing and returns to the preview', async () => {
  const s = setup(CE);
  const writes = editable(s, 0);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow', '내일 봐'));
  await until(() => s.btn('Undo'));
  s.btn('Deep').click();
  await until(() => s.calls.length === 2);
  s.pending[1].res(reply('see you tomorrow then', '내일 봐', 'claude-opus-5-5'));
  await sleep(10); // inside the 60 ms settle
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  await sleep(120);
  assert.deepEqual(writes, ['see you tomorrow']);
  assert.equal(s.box.textContent, 'see you tomorrow');
  assert.ok(s.btn('Undo'));
});

test('after Esc kept the translation, Alt+Z in the box restores the original, once', async () => {
  const s = setup();
  await toPreview(s);
  s.box.value = 'see you tomorrow!';
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.root(), undefined);
  assert.equal(s.key(s.ESC).defaultPrevented, false); // kept: Esc is the page's again
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  await until(() => s.box.value === '내일 봐');
  assert.equal(s.key(s.ALT_Z).defaultPrevented, false); // nothing left to undo
});

test('Esc during a re-run, then Alt+Z: the original comes back, not the previous translation', async () => {
  const s = setup();
  await toPreview(s);
  s.inst.run({ source: 'command' }); // Alt+T again in the preview: an Opus re-run
  await until(() => s.calls.length === 2);
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.box.value, 'see you tomorrow');
  assert.equal(s.key(s.ALT_Z).defaultPrevented, true);
  await until(() => s.box.value === '내일 봐');
  s.pending[1].res(reply('see you tomorrow, Opus'));
  await sleep(50);
  assert.equal(s.box.value, '내일 봐');
});

test('after Esc kept the translation, focus leaving the box ends Alt+Z undo', async () => {
  const s = setup();
  await toPreview(s);
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  s.doc.getElementById('o').focus();
  s.box.focus();
  assert.equal(s.key(s.ALT_Z).defaultPrevented, false);
  assert.equal(s.box.value, 'see you tomorrow');
});

test('Esc on a first request leaves nothing for Alt+Z to undo', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  assert.equal(s.key(s.ESC).defaultPrevented, true);
  assert.equal(s.key(s.ALT_Z).defaultPrevented, false);
  assert.equal(s.box.value, '내일 봐');
});

test('after Esc kept the translation, Alt+Z from another box is left alone', async () => {
  const s = setup();
  await toPreview(s);
  s.key(s.ESC);
  const other = s.doc.getElementById('o');
  assert.equal(s.key(s.ALT_Z, other).defaultPrevented, false); // focus never left the box; the key came from elsewhere
  assert.equal(s.box.value, 'see you tomorrow');
});

test('Deep re-runs with the hard profile and the card says so; a first run does not', async () => {
  const s = setup();
  await toPreview(s);
  assert.equal(s.root().querySelector('.model').textContent, 'Sonnet');
  assert.equal(s.btn('Opus'), undefined); // the default model is Opus already: the button names the difference
  s.btn('Deep').click();
  await until(() => s.calls.length === 2);
  assert.match(s.msg(), /^Translating deeply/);
  s.pending[1].res(reply('see you tomorrow then', '내일 봐', 'claude-opus-5-5'));
  await until(() => s.root()?.querySelector('.model')?.textContent === 'Opus deep');
});
