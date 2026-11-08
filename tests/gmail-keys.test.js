// Esc and Alt+Z in a Gmail compose body, through main.js start() and its document keydown listener with real
// KeyboardEvents, plus the compose.js paths those keys reach mid re-run, after an error and after Esc.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { GSEL } from '../src/content/gmail/selectors.js';
import { userNodes, nodesToText } from '../src/content/gmail/body.js';
import { translate } from '../src/content/gmail/compose.js';
import { start } from '../src/content/gmail/main.js';
import { shadowOf } from '../src/ui/card.js';

const html = readFileSync(new URL('./fixtures/gmail.html', import.meta.url), 'utf8');
const KOREAN = '한글 첫줄\n둘째 줄\n\n셋째 문단';
const flush = () => new Promise((r) => setTimeout(r, 0));
const ok = (translation, model = 'claude-sonnet-5-5') =>
  ({ ok: true, data: { lang: 'en', translation, back_translation: '역번역', model } });
const polished = (translation) => ({ ok: true, data: { translation, back_translation: '바뀐 점', model: 'claude-sonnet-5-5' } });
const userText = (body) => nodesToText(userNodes(body));

// A fresh Gmail page with main.js started on it. Every start() adds listeners to its own document only.
async function setup() {
  const win = new JSDOM(`<body>${html}</body>`).window;
  globalThis.document = win.document;
  globalThis.MutationObserver = win.MutationObserver;
  const calls = [];
  const pending = [];
  const commands = [];
  globalThis.chrome = {
    storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
    runtime: {
      getURL: (p) => `chrome-extension://x/${p}`,
      onMessage: { addListener: (f) => commands.push(f) },
      sendMessage: (msg) => {
        if (msg.type === 'badge') return Promise.resolve({ ok: true, data: true });
        calls.push(msg);
        return new Promise((res) => pending.push(res));
      },
    },
  };
  // fetchFonts would fetch a chrome-extension:// URL; fail it quietly instead of hitting the network stack.
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => Promise.reject(new Error('offline'));
  const realWarn = console.warn;
  console.warn = () => {};
  try {
    await start();
    await flush();
  } finally {
    globalThis.fetch = realFetch;
    console.warn = realWarn;
  }
  const [inline, dialog] = document.querySelectorAll(GSEL.body);
  const reply = async (r) => { pending.shift()(r); await flush(); };
  const note = () => {
    const hs = [...document.querySelectorAll('.pl-card')].map((h) => shadowOf(h).querySelector('.pl-root')).filter(Boolean);
    return hs.length ? hs : null;
  };
  const noteText = () => (note() || []).map((n) => n.textContent).join('|');
  // A real keydown on target. reached: whether a page listener on the target saw it (protly listens on document,
  // capture phase, before the page).
  const press = (target, init) => {
    let reached = false;
    const seen = () => { reached = true; };
    target.addEventListener('keydown', seen);
    const e = new win.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init });
    target.dispatchEvent(e);
    target.removeEventListener('keydown', seen);
    return { prevented: e.defaultPrevented, reached };
  };
  const ESC = { key: 'Escape', code: 'Escape' };
  const ALT_Z = { key: 'z', code: 'KeyZ', altKey: true };
  // Alt+T as the background sends it, answered by main.js's command listener.
  const altT = async (body) => {
    body.focus();
    let answer = null;
    let ran = false;
    const before = calls.length;
    commands.forEach((f) => f({ type: 'command' }, {}, (r) => { answer = r; }));
    // The listener waits one frame (a 16 ms timer in node) before translating; wait for the request, not a clock.
    for (let i = 0; i < 100 && !ran; i++) { await new Promise((r) => setTimeout(r, 5)); ran = calls.length > before; }
    return answer;
  };
  return { win, inline, dialog, calls, reply, note, noteText, press, ESC, ALT_Z, altT };
}

async function preview(t, text = 'First') {
  translate(t.inline);
  await t.reply(ok(text));
  assert.equal(userText(t.inline), text);
}

const UNSWALLOWED = { prevented: false, reached: true };
const SWALLOWED = { prevented: true, reached: false };

test('idle: Esc and Alt+Z reach Gmail untouched', async () => {
  const t = await setup();
  assert.deepEqual(t.press(t.inline, t.ESC), UNSWALLOWED);
  assert.deepEqual(t.press(t.inline, t.ALT_Z), UNSWALLOWED);
  assert.equal(userText(t.inline), KOREAN);
});

test('Esc in a preview keeps the edited translation, closes the card and is swallowed; the next Esc is Gmail\'s', async () => {
  const t = await setup();
  await preview(t);
  t.inline.firstChild.textContent = 'First, edited';
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(userText(t.inline), 'First, edited');
  assert.equal(t.note(), null);
  assert.deepEqual(t.press(t.inline, t.ESC), UNSWALLOWED);
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED); // kept: Alt+Z still restores
  assert.equal(userText(t.inline), KOREAN);
  assert.deepEqual(t.press(t.inline, t.ALT_Z), UNSWALLOWED); // nothing left to undo
});

test('kept, then edited: Alt+Z asks first; Keep my text closes the prompt, Esc closes it and is Gmail\'s', async () => {
  const t = await setup();
  await preview(t);
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  t.inline.firstChild.textContent = 'First, rewritten after Esc';
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED);
  assert.equal(userText(t.inline), 'First, rewritten after Esc');
  assert.match(t.noteText(), /drops your changes/);
  [...t.note()[0].querySelectorAll('button')].find((b) => b.textContent === 'Keep my text').click();
  assert.equal(t.note(), null);
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED);
  assert.deepEqual(t.press(t.inline, t.ESC), UNSWALLOWED);
  assert.equal(t.note(), null);
  assert.equal(userText(t.inline), 'First, rewritten after Esc');
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED);
  [...t.note()[0].querySelectorAll('button')].find((b) => b.textContent === 'Undo anyway').click();
  assert.equal(userText(t.inline), KOREAN);
  assert.equal(t.note(), null);
});

test('Alt+Z in a preview restores the Korean and is swallowed; a key from a node inside the body counts', async () => {
  const t = await setup();
  await preview(t, 'First\nSecond');
  const inner = t.inline.querySelector('div'); // the second paragraph's div
  assert.ok(inner && t.inline.contains(inner));
  assert.deepEqual(t.press(inner, t.ALT_Z), SWALLOWED);
  assert.equal(userText(t.inline), KOREAN);
  assert.equal(t.note(), null);
});

test('Option+Z (key "Ω", code KeyZ) undoes like Alt+Z', async () => {
  const t = await setup();
  await preview(t);
  assert.deepEqual(t.press(t.inline, { key: 'Ω', code: 'KeyZ', altKey: true }), SWALLOWED);
  assert.equal(userText(t.inline), KOREAN);
});

test('Ctrl+Alt+Z, Shift+Alt+Z, Meta+Alt+Z, plain Z and Alt+Y are not undo', async () => {
  const t = await setup();
  await preview(t);
  for (const init of [
    { key: 'z', code: 'KeyZ', altKey: true, ctrlKey: true },
    { key: 'Z', code: 'KeyZ', altKey: true, shiftKey: true },
    { key: 'z', code: 'KeyZ', altKey: true, metaKey: true },
    { key: 'z', code: 'KeyZ' },
    { key: 'z', code: 'KeyY', altKey: true }, // a QWERTZ Z: undo goes by the physical key
  ]) {
    assert.deepEqual(t.press(t.inline, init), UNSWALLOWED, JSON.stringify(init));
    assert.equal(userText(t.inline), 'First');
  }
  assert.match(t.noteText(), /역번역/); // the preview is still up
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED); // and still acts
});

test('Esc and Alt+Z during an IME composition are the IME\'s', async () => {
  const t = await setup();
  await preview(t);
  for (const init of [t.ESC, t.ALT_Z]) {
    const e = new t.win.KeyboardEvent('keydown', { bubbles: true, cancelable: true, isComposing: true, ...init });
    assert.equal(e.isComposing, true);
    t.inline.dispatchEvent(e);
    assert.equal(e.defaultPrevented, false);
  }
  assert.equal(userText(t.inline), 'First');
  assert.match(t.noteText(), /역번역/);
});

test('keys outside any compose body are ignored, also while a preview is up', async () => {
  const t = await setup();
  await preview(t);
  const outside = document.querySelector('[role="main"] [role="list"]');
  for (const target of [document.body, outside, t.inline.parentElement]) {
    assert.deepEqual(t.press(target, t.ESC), UNSWALLOWED);
    assert.deepEqual(t.press(target, t.ALT_Z), UNSWALLOWED);
  }
  assert.equal(userText(t.inline), 'First');
  assert.match(t.noteText(), /역번역/);
});

test('two composes: keys in one never touch the other', async () => {
  const t = await setup();
  await preview(t);
  t.dialog.replaceChildren(document.createTextNode('새 메일'));
  translate(t.dialog);
  await t.reply(ok('New mail'));
  assert.equal(t.note().length, 2);

  assert.deepEqual(t.press(t.dialog, t.ALT_Z), SWALLOWED);
  assert.equal(userText(t.dialog), '새 메일');
  assert.equal(userText(t.inline), 'First');
  assert.equal(t.note().length, 1); // the inline preview's card is still up
  assert.match(t.noteText(), /역번역/);

  assert.deepEqual(t.press(t.dialog, t.ESC), UNSWALLOWED); // the dialog is idle now
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(userText(t.inline), 'First');
  assert.equal(t.note(), null);
});

test('Esc while the first request is in flight keeps the Korean and drops the late result', async () => {
  const t = await setup();
  translate(t.inline);
  assert.match(t.noteText(), /Translating/);
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(t.note(), null);
  await t.reply(ok('Late'));
  assert.equal(userText(t.inline), KOREAN);
  assert.equal(t.note(), null);
});

test('Esc during an Opus re-run keeps the previous translation; the late result never lands', async () => {
  const t = await setup();
  await preview(t);
  [...t.note()[0].querySelectorAll('button')].find((b) => b.textContent === 'Opus').click();
  assert.match(t.noteText(), /with Opus/);
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(userText(t.inline), 'First');
  assert.equal(t.note(), null);
  await t.reply(ok('Second', 'claude-opus-5-5'));
  assert.equal(userText(t.inline), 'First');
  assert.equal(t.note(), null);
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED); // kept: the original is still there to restore
  assert.equal(userText(t.inline), KOREAN);
});

test('Alt+Z during a language re-run restores the Korean, not the previous translation', async () => {
  const t = await setup();
  await preview(t);
  const sel = t.note()[0].querySelector('select');
  sel.value = 'ja';
  sel.dispatchEvent(new t.win.Event('change'));
  assert.equal(t.calls[1].lang, 'ja');
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED);
  assert.equal(userText(t.inline), KOREAN);
  assert.equal(t.note(), null);
  await t.reply(ok('二番目'));
  assert.equal(userText(t.inline), KOREAN);
  assert.equal(t.note(), null);
});

test('Esc on the "you edited the translation" prompt keeps the edit and sends nothing', async () => {
  const t = await setup();
  await preview(t);
  t.inline.firstChild.textContent = 'First, edited';
  [...t.note()[0].querySelectorAll('button')].find((b) => b.textContent === 'Opus').click();
  assert.match(t.noteText(), /You edited the translation/);
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(userText(t.inline), 'First, edited');
  assert.equal(t.note(), null);
  assert.equal(t.calls.length, 1);
});

test('after a failed first request Esc is Gmail\'s; after a failed re-run it keeps the translation', async () => {
  const t = await setup();
  translate(t.inline);
  await t.reply({ ok: false, error: { kind: 'host', message: 'port closed' } });
  assert.match(t.noteText(), /Native host not reachable/);
  assert.deepEqual(t.press(t.inline, t.ESC), UNSWALLOWED); // idle: nothing of protly's to keep
  assert.deepEqual(t.press(t.inline, t.ALT_Z), UNSWALLOWED);
  assert.equal(userText(t.inline), KOREAN);

  await preview(t);
  [...t.note()[0].querySelectorAll('button')].find((b) => b.textContent === 'Opus').click();
  await t.reply({ ok: false, error: { kind: 'timeout', message: 'slow' } });
  assert.match(t.noteText(), /too long/);
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.equal(userText(t.inline), 'First');
  assert.equal(t.note(), null);
});

test('after Esc, Alt+T on the kept English polishes it and Undo goes back to that English', async () => {
  const t = await setup();
  await preview(t, 'I has a question.');
  assert.deepEqual(t.press(t.inline, t.ESC), SWALLOWED);
  assert.deepEqual(await t.altT(t.inline), { handled: true });
  assert.deepEqual(t.calls[1], { type: 'polish', text: 'I has a question.', profile: 'email' });
  await t.reply(polished('I have a question.'));
  assert.equal(userText(t.inline), 'I have a question.');
  assert.deepEqual(t.press(t.inline, t.ALT_Z), SWALLOWED);
  // Esc made the kept translation the draft: Undo restores it, the Korean is not coming back.
  assert.equal(userText(t.inline), 'I has a question.');
});
