import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { createInstance } from '../src/generic/instance.js';
import { shadowOf } from '../src/ui/card.js';
import { ERRORS } from '../src/ui/errors.js';
import { _resetToasts } from '../src/ui/toast.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 1500) {
  const end = Date.now() + ms;
  while (!fn()) { if (Date.now() > end) throw new Error('timed out'); await sleep(5); }
}
const reply = (translation, back = '역번역', model = 'claude-sonnet-5-5', lang = 'en') =>
  ({ translation, back_translation: back, model, lang });

function setup(html = '<textarea id="b"></textarea>') {
  _resetToasts();
  const dom = new JSDOM(`<body>${html}</body>`, { url: 'https://forum.example.org/post' });
  const doc = dom.window.document;
  const calls = [];
  const pending = [];
  const ask = (msg) => { calls.push(msg); return new Promise((res, rej) => pending.push({ res, rej })); };
  const inst = createInstance({ doc, ask, fonts: null });
  const root = () => { const h = doc.querySelector('.pl-card'); return h ? shadowOf(h) : undefined; };
  const msg = () => root()?.querySelector('.msg')?.textContent ?? null;
  const btn = (label) => [...(root()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  const toasts = () => doc.querySelector('.pl-toasts')?.shadowRoot?.textContent ?? '';
  const box = doc.getElementById('b');
  return { dom, doc, calls, pending, inst, root, msg, btn, toasts, box };
}

test('Korean in a textarea: box call with the hostname, write, preview, Undo restores', async () => {
  const { calls, pending, inst, msg, btn, root, box } = setup();
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'box', text: '내일 봐', lang: 'en', profile: 'outgoing', hostname: 'forum.example.org' });
  assert.match(msg(), /Translating/);
  pending[0].res(reply('see you tomorrow', '내일 봐'));
  await until(() => box.value === 'see you tomorrow');
  await until(() => btn('Undo'));
  assert.match(msg(), /내일 봐/);
  assert.ok(btn('Deep'));
  assert.ok(root().querySelector('select.pl-chip'));
  btn('Undo').click();
  await until(() => box.value === '내일 봐');
  assert.equal(root(), undefined);
});

test('English: polish call, no language chip', async () => {
  const { calls, pending, inst, root, btn, box } = setup();
  box.value = 'i has a question';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'polish', text: 'i has a question', profile: 'polish' });
  pending[0].res({ translation: 'I have a question', back_translation: '문법', model: 'claude-sonnet-5-5' });
  await until(() => btn('Undo'));
  assert.equal(root().querySelector('select.pl-chip'), null);
});

test('a prefix picks the language and drops the prefix', async () => {
  const { calls, inst, box } = setup();
  box.value = 'ru: 안녕';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  assert.equal(calls[0].lang, 'ru');
  assert.equal(calls[0].text, '안녕');
});

test('Alt+T again while the preview is open re-runs on Opus', async () => {
  const { calls, pending, inst, btn, box } = setup();
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].res(reply('see you tomorrow'));
  await until(() => btn('Undo'));
  inst.run({ source: 'command' });
  await until(() => calls.length === 2);
  assert.equal(calls[1].profile, 'hard');
  assert.equal(calls[1].text, '내일 봐'); // the original, not the shown translation
});

test('Esc in the box during the preview keeps the translation; Alt+Z undoes', async () => {
  const { dom, calls, pending, inst, btn, box, root } = setup();
  const key = (init) => { const e = new dom.window.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }); box.dispatchEvent(e); return e; };
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].res(reply('see you tomorrow'));
  await until(() => btn('Undo'));
  box.value = 'see you tomorrow!';
  assert.equal(key({ key: 'Escape' }).defaultPrevented, true);
  assert.equal(box.value, 'see you tomorrow!');
  assert.equal(root(), undefined);
  assert.equal(key({ key: 'Escape' }).defaultPrevented, false); // nothing left to keep: the page gets it

  inst.run({ source: 'command' });
  await until(() => calls.length === 2);
  pending[1].res(reply('see you tomorrow'));
  await until(() => btn('Undo'));
  assert.equal(key({ key: 'Ω', code: 'KeyZ', altKey: true }).defaultPrevented, true); // Option+Z on a Mac
  await until(() => box.value === 'see you tomorrow!');
});

test('text typed while working: the result is dropped, the box is left alone', async () => {
  const { calls, pending, inst, msg, box } = setup();
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  box.value = '내일 봐 ㅋㅋ';
  pending[0].res(reply('see you tomorrow'));
  await until(() => /dropped/.test(msg() || ''));
  assert.equal(box.value, '내일 봐 ㅋㅋ');
});

test('an auth error shows in the card and as a page toast', async () => {
  const { calls, pending, inst, msg, toasts, box } = setup();
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].rej(Object.assign(new Error('401'), { kind: 'auth' }));
  await until(() => msg() === ERRORS.auth);
  assert.match(toasts(), /API key missing/);
  assert.equal(box.value, '내일 봐');
});

test('nothing focused and nothing selected: a toast, no call', async () => {
  const { calls, inst, toasts } = setup('<p>text</p>');
  await inst.run({ source: 'command' });
  assert.match(toasts(), /Put the cursor in a text box or select text\./);
  assert.equal(calls.length, 0);
});

test('menu selection: Korean gets a toast, other text a popover with the translation', async () => {
  const { calls, pending, inst, msg, btn, toasts } = setup('<p>text</p>');
  await inst.run({ source: 'menu-selection', selectionText: '안녕하세요' });
  assert.match(toasts(), /Already Korean\./);
  assert.equal(calls.length, 0);
  inst.run({ source: 'menu-selection', selectionText: 'see you' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'selection', text: 'see you' });
  pending[0].res({ src_lang: 'en', translation: '또 봐' });
  await until(() => msg() === '또 봐');
  assert.ok(btn('Close'));
});

test('toast() shows a message in the page', () => {
  const { inst, toasts } = setup('<p>x</p>');
  inst.toast('protly cannot reach this frame.');
  assert.match(toasts(), /cannot reach this frame/);
});

// A contenteditable box whose execCommand stub writes after delayMs (0: at once).
function editable(s, delayMs = 0) {
  const calls = [];
  s.doc.execCommand = (cmd, ui, text) => {
    calls.push(text);
    const set = () => { s.box.textContent = text; };
    if (delayMs) setTimeout(set, delayMs); else set();
    return true;
  };
  return calls;
}
const CE = '<div id="b" contenteditable="true" tabindex="0"></div><input id="o">';

// chrome.dom.openOrClosedShadowRoot as a content script has it: open roots, protly's own closed card root, and the
// closed roots a test registers. Returns the undo.
function chromeDom(closed = new Map()) {
  globalThis.chrome = { dom: { openOrClosedShadowRoot: (el) => el.shadowRoot ?? shadowOf(el) ?? closed.get(el) ?? null } };
  return () => { delete globalThis.chrome; };
}

test('contenteditable that renders the insert late (Slate, Draft.js): preview, not an error', async () => {
  const s = setup(CE);
  editable(s, 80);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  assert.equal(s.box.textContent, 'see you tomorrow');
});

test('Esc during the select settle cancels the write', async () => {
  const s = setup(CE);
  const writes = editable(s);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await sleep(10); // inside the 60 ms settle
  s.box.dispatchEvent(new s.dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  await sleep(120);
  assert.deepEqual(writes, []);
  assert.equal(s.box.textContent, '내일 봐');
  assert.equal(s.root(), undefined);
});

test('a composition that commits more text before the write: result dropped', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.box.dispatchEvent(new s.dom.window.Event('compositionstart', { bubbles: true }));
  s.pending[0].res(reply('see you tomorrow'));
  await sleep(10);
  s.box.value = '내일 봐요';
  s.box.dispatchEvent(new s.dom.window.Event('compositionend', { bubbles: true }));
  await until(() => /draft changed/.test(s.msg() || ''));
  assert.equal(s.box.value, '내일 봐요');
});

test('focus moved while working: a textarea is written without taking focus back', async () => {
  const s = setup('<textarea id="b"></textarea><input id="o">');
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  const other = s.doc.getElementById('o');
  other.focus();
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.box.value === 'see you tomorrow');
  await until(() => s.btn('Undo'));
  assert.equal(s.doc.activeElement, other);
});

test('focus moved into an input while working: a contenteditable is left alone, with a toast', async () => {
  const s = setup(CE);
  const writes = editable(s);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  const other = s.doc.getElementById('o');
  other.focus();
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => /Focus moved, so the translation was not written\./.test(s.toasts()));
  assert.deepEqual(writes, []);
  assert.equal(s.box.textContent, '내일 봐');
  assert.equal(s.doc.activeElement, other);
  assert.equal(s.root(), undefined);
});

// Outlook: a long email takes a while, and a click on the page, a scroll or the autosave blurs the body.
const focusOn = (id) => (s) => s.doc.getElementById(id).focus();
for (const [what, move] of [
  ['blurred to the page', (s) => s.box.blur()],
  ['onto a button', focusOn('btn')],
  ['onto a non-editable element with tabindex', focusOn('pane')],
  ['onto a checkbox', focusOn('cb')],
  ['onto a submit input', focusOn('sub')],
  ['onto a custom toolbar button with no shadow root', focusOn('md')],
  ['onto a custom tab whose open shadow root holds no field', (s) => {
    s.doc.getElementById('tab').attachShadow({ mode: 'open' }).innerHTML = '<span>Inbox</span>';
    s.doc.getElementById('tab').focus();
  }],
  ['onto the custom composer wrapping the box (a click in its padding)', focusOn('w')],
]) {
  test(`focus ${what} while working: a contenteditable is still written and keeps the preview`, async (t) => {
    t.after(chromeDom());
    const s = setup(`<x-composer id="w" tabindex="-1">${CE}</x-composer><button id="btn">Send</button>`
      + '<div id="pane" tabindex="0">quoted mail</div><input id="cb" type="checkbox"><input id="sub" type="submit">'
      + '<md-bold id="md" tabindex="0">B</md-bold><x-tab id="tab" tabindex="0"></x-tab>');
    const writes = editable(s);
    s.box.textContent = '내일 봐';
    s.box.focus();
    s.inst.run({ source: 'command' });
    await until(() => s.calls.length === 1);
    move(s);
    assert.notEqual(s.doc.activeElement, s.box);
    s.pending[0].res(reply('see you tomorrow'));
    await until(() => s.btn('Undo'));
    assert.deepEqual(writes, ['see you tomorrow']);
    assert.equal(s.box.textContent, 'see you tomorrow');
    assert.equal(s.doc.activeElement, s.box);
    assert.doesNotMatch(s.toasts(), /Focus moved/);
  });
}

for (const field of ['<input id="f" type="password">', '<input id="f" type="number">', '<input id="f" readonly>', '<select id="f"><option>a</option></select>']) {
  test(`focus moved into ${field} while working: a contenteditable is left alone`, async () => {
    const s = setup(`${CE}${field}`);
    const writes = editable(s);
    s.box.textContent = '내일 봐';
    s.box.focus();
    s.inst.run({ source: 'command' });
    await until(() => s.calls.length === 1);
    const f = s.doc.getElementById('f');
    f.focus();
    s.pending[0].res(reply('see you tomorrow'));
    await until(() => /Focus moved, so the translation was not written\./.test(s.toasts()));
    assert.deepEqual(writes, []);
    assert.equal(s.doc.activeElement, f);
  });
}

test('focus moved into another contenteditable while working: left alone, with a toast', async () => {
  const s = setup(`${CE}<div id="o2" contenteditable="true" tabindex="0"></div>`);
  const writes = editable(s);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  const other = s.doc.getElementById('o2');
  other.focus();
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => /Focus moved, so the translation was not written\./.test(s.toasts()));
  assert.deepEqual(writes, []);
  assert.equal(s.box.textContent, '내일 봐');
  assert.equal(s.doc.activeElement, other);
});

for (const host of ['x-field', 'div']) {
  test(`focus moved into a field in a closed shadow root on a <${host}> while working: a contenteditable is left alone`, async (t) => {
    const closed = new Map();
    t.after(chromeDom(closed));
    const s = setup(`${CE}<${host} id="x"></${host}>`);
    const writes = editable(s);
    const x = s.doc.getElementById('x');
    const input = s.doc.createElement('input');
    const root = x.attachShadow({ mode: 'closed' });
    root.appendChild(input);
    closed.set(x, root);
    s.box.textContent = '내일 봐';
    s.box.focus();
    s.inst.run({ source: 'command' });
    await until(() => s.calls.length === 1);
    input.focus();
    assert.equal(s.doc.activeElement, x); // the page sees only the host
    s.pending[0].res(reply('see you tomorrow'));
    await until(() => /Focus moved, so the translation was not written\./.test(s.toasts()));
    assert.deepEqual(writes, []);
    assert.equal(s.box.textContent, '내일 봐');
  });
}

// The working card drops the chip, so focus falls to the page and the box is taken back. With chrome.dom in
// place, a chip still focused at the write (inside the card's closed root) would refuse it and fail this test.
test('the language chip on a contenteditable: the re-run is written after focus was on the chip', async (t) => {
  t.after(chromeDom());
  const s = setup(CE);
  const writes = editable(s);
  s.box.textContent = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  const chip = s.root().querySelector('select.pl-chip');
  chip.focus();
  chip.value = 'ru';
  chip.dispatchEvent(new s.dom.window.Event('change', { bubbles: true }));
  await until(() => s.calls.length === 2);
  assert.equal(s.calls[1].lang, 'ru');
  s.pending[1].res(reply('до завтра'));
  await until(() => writes.length === 2);
  assert.deepEqual(writes, ['see you tomorrow', 'до завтра']);
  assert.doesNotMatch(s.toasts(), /Focus moved/);
});

test('a box inside a shadow root: Alt+Z in it undoes', async () => {
  const s = setup('<div id="h"></div>');
  const sr = s.doc.getElementById('h').attachShadow({ mode: 'open' });
  const box = s.doc.createElement('textarea');
  sr.appendChild(box);
  box.value = '내일 봐';
  box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  box.dispatchEvent(new s.dom.window.KeyboardEvent('keydown', { key: 'z', code: 'KeyZ', altKey: true, bubbles: true, composed: true }));
  await until(() => box.value === '내일 봐');
});

test('blur to nothing closes the preview; focus on the chip keeps it', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  s.root().querySelector('select.pl-chip').focus();
  assert.equal(s.doc.activeElement, s.doc.querySelector('.pl-card'));
  await sleep(20);
  assert.ok(s.btn('Undo'));
  s.box.focus();
  s.box.blur(); // a click on plain text
  await until(() => s.root() === undefined);
  assert.equal(s.box.value, 'see you tomorrow');
});

test('preview open, focus on the chip, page text selected: Alt+T translates the selection', async () => {
  const s = setup('<textarea id="b"></textarea><p id="p">see you</p>');
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  s.root().querySelector('select.pl-chip').focus();
  assert.equal(s.doc.activeElement, s.doc.querySelector('.pl-card'));
  const r = s.doc.createRange();
  r.selectNodeContents(s.doc.getElementById('p'));
  s.doc.getSelection().removeAllRanges();
  s.doc.getSelection().addRange(r);
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 2);
  assert.deepEqual(s.calls[1], { type: 'selection', text: 'see you' });
});

test('menu-editable on the same box during the preview re-runs on Opus', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  s.inst.run({ source: 'menu-editable' });
  await until(() => s.calls.length === 2);
  assert.equal(s.calls[1].type, 'box');
  assert.equal(s.calls[1].profile, 'hard');
  assert.equal(s.calls[1].text, '내일 봐');
});

test('a box in an open modal dialog gets its card inside the dialog', async () => {
  const s = setup('<dialog open><textarea id="b"></textarea></dialog>');
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  assert.equal(s.doc.querySelector('.pl-card').parentNode, s.doc.querySelector('dialog'));
});

test('a second Alt+T while the box is being read sends no second request', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  await sleep(50);
  assert.equal(s.calls.length, 1);
});

test('over 12000 characters: a toast, no call', async () => {
  const s = setup();
  s.box.value = '가'.repeat(12001);
  s.box.focus();
  await s.inst.run({ source: 'command' });
  assert.match(s.toasts(), /Too long for protly \(over 12000 characters\)\./);
  _resetToasts();
  await s.inst.run({ source: 'menu-selection', selectionText: 'a'.repeat(12001) });
  assert.match(s.toasts(), /Too long for protly/);
  assert.equal(s.calls.length, 0);
});

test('focus in a cross-origin frame: a toast, no stale re-run', async () => {
  const s = setup();
  s.box.value = '내일 봐';
  s.box.focus();
  s.inst.run({ source: 'command' });
  await until(() => s.calls.length === 1);
  s.pending[0].res(reply('see you tomorrow'));
  await until(() => s.btn('Undo'));
  const frame = { tagName: 'IFRAME', contentDocument: null };
  Object.defineProperty(s.doc, 'activeElement', { get: () => frame, configurable: true });
  await s.inst.run({ source: 'command' });
  assert.match(s.toasts(), /protly cannot reach this frame\. Right-click inside the box instead\./);
  assert.equal(s.calls.length, 1);
});

// Bracket notes (plan docs/plans/2026-11-08-notes-and-iphone-port.md, Part A).
const NOTES_ONLY = 'Add the message too. [Brackets] are notes for protly.';
const NOTE_ON_TRANSLATION = 'Notes work on a new draft. Undo first, then add the note.';

test('notes: Korean with a note sends the text and the notes, Deep keeps them, Undo restores the draft', async () => {
  const { calls, pending, inst, btn, box } = setup();
  box.value = '내일 봐 [정중하게]';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'box', text: '내일 봐', lang: 'en', profile: 'outgoing', hostname: 'forum.example.org', notes: ['정중하게'] });
  pending[0].res(reply('see you tomorrow'));
  await until(() => btn('Deep'));
  btn('Deep').click();
  await until(() => calls.length === 2);
  assert.deepEqual([calls[1].profile, calls[1].text, calls[1].notes], ['hard', '내일 봐', ['정중하게']]);
  pending[1].res(reply('See you tomorrow.'));
  await until(() => box.value === 'See you tomorrow.');
  await until(() => btn('Undo'));
  btn('Undo').click();
  await until(() => box.value === '내일 봐 [정중하게]');
});

test('notes: English with a note is polished with its notes', async () => {
  const { calls, inst, box } = setup();
  box.value = 'see you [formal]';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'polish', text: 'see you', profile: 'polish', notes: ['formal'] });
});

test('notes: a box of notes only runs nothing and says why', async () => {
  const { calls, inst, box, toasts } = setup();
  box.value = '[formal]';
  box.focus();
  await inst.run({ source: 'command' });
  await until(() => toasts().includes(NOTES_ONLY));
  assert.equal(calls.length, 0);
});

test('notes: a note typed into the preview holds Alt+T and Deep; the original still comes back', async () => {
  const { calls, pending, inst, btn, box, msg } = setup();
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].res(reply('see you tomorrow'));
  await until(() => btn('Undo'));
  box.value = 'see you tomorrow [shorter]';
  await inst.run({ source: 'command' });
  assert.equal(msg(), NOTE_ON_TRANSLATION);
  btn('Deep').click();
  await sleep(10);
  assert.equal(msg(), NOTE_ON_TRANSLATION);
  assert.equal(calls.length, 1);
  btn('Undo').click();
  await until(() => box.value === '내일 봐');
});

test('notes: a note typed into a kept translation holds Alt+T; Alt+Z still restores the original', async () => {
  const { dom, calls, pending, inst, btn, box, toasts } = setup();
  const key = (init) => { const e = new dom.window.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }); box.dispatchEvent(e); return e; };
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].res(reply('see you tomorrow'));
  await until(() => btn('Undo'));
  assert.equal(key({ key: 'Escape' }).defaultPrevented, true);
  box.value = 'see you tomorrow [shorter]';
  await inst.run({ source: 'command' });
  await until(() => toasts().includes(NOTE_ON_TRANSLATION));
  assert.equal(calls.length, 1);
  assert.equal(key({ key: 'z', code: 'KeyZ', altKey: true }).defaultPrevented, true);
  await until(() => box.value === '내일 봐');
});

test('notes: brackets the kept translation already had are not a new note', async () => {
  const { dom, calls, pending, inst, btn, box } = setup();
  const key = (init) => { const e = new dom.window.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }); box.dispatchEvent(e); return e; };
  box.value = '내일 봐';
  box.focus();
  inst.run({ source: 'command' });
  await until(() => calls.length === 1);
  pending[0].res(reply('see you [tomorrow]'));
  await until(() => btn('Undo'));
  assert.equal(key({ key: 'Escape' }).defaultPrevented, true);
  inst.run({ source: 'command' }); // Alt+T on the kept translation polishes it, as without brackets
  await until(() => calls.length === 2);
  assert.equal(calls[1].type, 'polish');
});

test('notes: a selection keeps its brackets and sends no notes', async () => {
  const { calls, inst } = setup();
  inst.run({ source: 'menu-selection', selectionText: 'see [you] later' });
  await until(() => calls.length === 1);
  assert.deepEqual(calls[0], { type: 'selection', text: 'see [you] later' });
});
