// WhatsApp Web with the loader's early key relay: when protly acts on Esc (keep) or Alt+Z (undo), WhatsApp's own
// window listeners, added before protly mounts, never see the key; when protly does not act, they do. One start() per
// file (whatsapp-mount.test.js says why).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';

const KOREAN = '지민아 또 봐';
const SHOWN = 'See you, 지민';

const until = async (f, ms = 5000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 2));
  }
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

test('WhatsApp: Esc and Alt+Z reach the page only when protly does not act on them', async () => {
  const win = new JSDOM('<body><div id="app"></div></body>', { url: 'https://web.whatsapp.com/' }).window;
  const doc = win.document;
  for (const k of ['window', 'document', 'location', 'MutationObserver', 'Option', 'Node', 'getComputedStyle']) {
    globalThis[k] = k === 'window' ? win : win[k];
  }
  const asked = [];
  const pending = [];
  let mounts = 0;
  globalThis.chrome = {
    storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
    runtime: {
      id: 'protly',
      getURL: (p) => `chrome-extension://protly/${p}`,
      onMessage: { addListener: () => { mounts++; }, removeListener() {} },
      sendMessage: (msg) => {
        asked.push(msg);
        if (msg.type === 'getThread') return Promise.resolve({ ok: true, data: { enabled: true, outputLang: 'auto', otherTarget: 'ko', pastMode: 'replace', newMode: 'below', memo: '' } });
        if (msg.type === 'outgoing' || msg.type === 'polish') return new Promise((resolve) => pending.push(resolve));
        return Promise.resolve({ ok: true, data: true });
      },
    },
  };
  globalThis.fetch = async () => ({ ok: false, status: 404 });
  const realSetInterval = globalThis.setInterval;
  globalThis.setInterval = (f, ms) => realSetInterval(f, ms).unref(); // main.js's poll must not keep the test alive

  // The real loader at document_start, then WhatsApp's own early listener, then the chat.
  const loaderSrc = readFileSync(new URL('../src/content/whatsapp/loader.js', import.meta.url), 'utf8');
  new Function('window', 'document', 'chrome', 'console', loaderSrc)(
    win, doc, { runtime: { getURL: () => 'data:text/javascript,throw 0' } }, { error() {} });
  const pageSaw = [];
  for (const type of ['keydown', 'keyup']) {
    win.addEventListener(type, (e) => { if (e.key !== 'Enter') pageSaw.push(`${type} ${e.key}`); }, true);
  }
  doc.querySelector('#app').innerHTML = `<div id="main"><header><span data-testid="conversation-info-header-chat-title">Test
    Partner</span></header><div data-testid="conversation-panel-messages"></div><footer><div><div contenteditable="true"
    role="textbox" data-lexical-editor="true"></div></div></footer></div>`;
  const composer = doc.querySelector('#main footer [role="textbox"]');
  Object.defineProperty(composer, 'isContentEditable', { value: true });
  Object.defineProperty(composer, 'innerText', { get: () => composer.textContent });
  doc.execCommand = (cmd, ui, text) => {
    composer.textContent = doc.getSelection().toString() === composer.textContent ? text : composer.textContent + text;
    return true;
  };

  const key = (type, init) => {
    const e = new win.KeyboardEvent(type, { bubbles: true, cancelable: true, ...init });
    composer.dispatchEvent(e);
    return e;
  };
  const press = (init) => { const down = key('keydown', init); key('keyup', init); return down.defaultPrevented; };
  const ESC = { key: 'Escape', code: 'Escape' };
  const ALT_Z = { key: 'z', code: 'KeyZ', altKey: true };
  const hints = () => { const h = doc.querySelector('.pl-card'); return h ? shadowOf(h).querySelector('.hints') : null; };

  const { _trustSyntheticEvents } = await import('../src/ui/trust.js');
  const { shadowOf } = await import('../src/ui/card.js');
  const { start } = await import('../src/content/whatsapp/site.js');
  await start();
  await until(() => mounts === 1);
  _trustSyntheticEvents(true);
  try {
    composer.textContent = KOREAN;
    composer.focus();
    assert.equal(key('keydown', { key: 'Enter', code: 'Enter' }).defaultPrevented, true);
    pending.shift()({ ok: true, data: { translation: SHOWN, back_translation: KOREAN, lang: 'en', model: 'm' } });
    await until(() => composer.textContent === SHOWN && hints());
    await wait(200); // past the write check
    pageSaw.length = 0;

    // Preview: Esc keeps the translation; WhatsApp sees neither its keydown nor its keyup (a quote-reply survives).
    assert.equal(press(ESC), true);
    assert.equal(doc.querySelector('.pl-card'), null);
    assert.deepEqual(pageSaw, []);

    // Kept: Esc is WhatsApp's again.
    assert.equal(press(ESC), false);
    assert.deepEqual(pageSaw, ['keydown Escape', 'keyup Escape']);
    assert.equal(composer.textContent, SHOWN);

    // Kept: Alt+Z puts the Korean back; WhatsApp never sees its keydown.
    pageSaw.length = 0;
    assert.equal(key('keydown', ALT_Z).defaultPrevented, true);
    assert.deepEqual(pageSaw, []);
    await until(() => composer.textContent === KOREAN);
    await wait(200);

    // Idle: Alt+Z is WhatsApp's.
    assert.equal(key('keydown', ALT_Z).defaultPrevented, false);
    assert.deepEqual(pageSaw, ['keydown z']);
  } finally {
    _trustSyntheticEvents(false);
  }
});
