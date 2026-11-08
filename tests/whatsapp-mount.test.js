// WhatsApp Web as mounted by the content script: a title selector miss, a late title, a chat switch (WhatsApp
// replaces #main), a real Enter, and closing and reopening a chat. One start() per file: every start() adds its own
// hooks, guard and poll loop.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';

const PAGE = '<body><div id="app"></div></body>';
const TITLE = 'conversation-info-header-chat-title';
const row = (text) => `<div role="row"><div data-testid="conv-msg-x"><div class="copyable-text">
  <span data-testid="selectable-text"><span>${text}</span></span></div><div data-testid="msg-meta"></div></div></div>`;

const flush = () => new Promise((r) => setImmediate(r)); // setImmediate is not mocked
const advance = async (ms) => { for (let t = 0; t < ms; t += 100) { mock.timers.tick(100); await flush(); } };

test('WhatsApp: Hangul Enter is never let through, from a title miss to a chat switch and a reopened chat', async () => {
  const win = new JSDOM(PAGE, { url: 'https://web.whatsapp.com/' }).window;
  const doc = win.document;
  for (const k of ['window', 'document', 'location', 'MutationObserver', 'Option', 'Node', 'getComputedStyle']) {
    globalThis[k] = k === 'window' ? win : win[k];
  }
  const asked = [];
  let mounts = 0;
  globalThis.chrome = {
    storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
    runtime: {
      id: 'protly',
      getURL: (p) => `chrome-extension://protly/${p}`,
      onMessage: { addListener: () => { mounts++; }, removeListener() {} }, // outgoing.js's Alt+T listener, per mount
      sendMessage: (msg) => {
        asked.push(msg);
        if (msg.type === 'getThread') return Promise.resolve({ ok: true, data: { enabled: true, outputLang: 'auto', otherTarget: 'ko', pastMode: 'replace', newMode: 'below', memo: '' } });
        if (msg.type === 'outgoing' || msg.type === 'polish') return new Promise(() => {}); // billed: never answers
        return Promise.resolve({ ok: true, data: true });
      },
    },
  };
  globalThis.fetch = async () => ({ ok: false, status: 404 }); // fonts: the monospace fallback

  let pageSaw = 0;
  // A chat as WhatsApp renders it: a new #main node every time.
  const openChat = (title, rows = []) => {
    doc.querySelector('#main')?.remove();
    doc.querySelector('#app').insertAdjacentHTML('beforeend', `<div id="main"><header><div class="title-slot">${
      title === null ? '' : `<span data-testid="${TITLE}">${title}</span>`
    }</div></header><div data-testid="conversation-panel-messages">${rows.map(row).join('')}</div>
      <footer><div><div contenteditable="true" role="textbox" data-lexical-editor="true"></div></div></footer></div>`);
    const c = doc.querySelector('#main footer [role="textbox"]');
    // jsdom implements neither: main.js's guard reads isContentEditable (see src/generic/target.js), and there is
    // no layout text.
    Object.defineProperty(c, 'isContentEditable', { value: true });
    Object.defineProperty(c, 'innerText', { get: () => c.textContent });
    c.addEventListener('keydown', () => { pageSaw++; }); // WhatsApp's own send handler sits here
    return c;
  };
  const hangulEnter = (c) => {
    c.textContent = '안녕';
    const e = new win.KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
    c.dispatchEvent(e);
    return e;
  };
  // Reply with text already in the box leaves focus on the message row; WhatsApp sends the box on its Enter.
  let rowSaw = 0;
  const rowEnter = (c) => {
    c.textContent = '안녕';
    const r = doc.querySelector('#main [data-testid^="conv-msg-"]');
    r.addEventListener('keydown', () => { rowSaw++; });
    const e = new win.KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
    r.dispatchEvent(e);
    return e;
  };
  const threadIds = () => asked.filter((m) => m.type === 'getThread').map((m) => m.threadId);

  // The real loader, as at document_start: its key relay goes on window before WhatsApp's own listener. Its import
  // fails here on purpose (this test starts site.js itself).
  const loaderSrc = readFileSync(new URL('../src/content/whatsapp/loader.js', import.meta.url), 'utf8');
  new Function('window', 'document', 'chrome', 'console', loaderSrc)(
    win, doc, { runtime: { getURL: () => 'data:text/javascript,throw 0' } }, { error() {} });
  let pageEsc = 0; // WhatsApp's own early listener: it cancels a quote-reply on Escape
  for (const type of ['keydown', 'keyup']) win.addEventListener(type, (e) => { if (e.key === 'Escape') pageEsc++; }, true);

  let composer = openChat(null);
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const { _trustSyntheticEvents } = await import('../src/ui/trust.js');
  try {
    const { start } = await import('../src/content/whatsapp/site.js');
    await start();

    // 1. #main but no title: the id is wa-untitled and the guard holds the Enter.
    assert.equal(hangulEnter(composer).defaultPrevented, true);
    assert.equal(pageSaw, 0);

    // 2. The wait gives up after about 10 s and says why.
    await advance(12000);
    assert.ok(asked.some((m) => m.type === 'badge' && m.reason === 'WhatsApp thread not found'));
    assert.equal(mounts, 0);

    // 3. The title shows up: the poll sees a new id (wa-untitled -> wa-<hash>) and mounts the thread.
    const title = doc.createElement('span');
    title.dataset.testid = TITLE;
    title.textContent = 'Test Partner';
    doc.querySelector('.title-slot').append(title);
    await advance(3000);
    assert.equal(mounts, 1);
    const [idA] = threadIds();
    assert.match(idA, /^wa-[0-9a-f]{14}$/);

    // 4. The mounted outgoing handler holds a synthetic Enter and bills nothing.
    asked.length = 0;
    assert.equal(hangulEnter(composer).defaultPrevented, true);
    await flush();
    assert.equal(pageSaw, 0);
    assert.deepEqual(asked.filter((m) => m.type === 'outgoing' || m.type === 'polish'), []);

    // 5. Switch chats: before the poll notices, the guard holds the Enter in the new box; then B mounts under its id.
    composer = openChat('Other Chat', ['hello']);
    assert.equal(hangulEnter(composer).defaultPrevented, true);
    assert.equal(pageSaw, 0);
    assert.equal(rowEnter(composer).defaultPrevented, true); // also from a focused message
    assert.equal(rowSaw, 0);
    await advance(3000);
    assert.equal(mounts, 2);
    const idB = threadIds().at(-1);
    assert.match(idB, /^wa-[0-9a-f]{14}$/);
    assert.notEqual(idB, idA);

    // 6. The user's own Enter in B starts a translation for B's thread instead of sending.
    _trustSyntheticEvents(true);
    const own = hangulEnter(composer);
    await flush();
    _trustSyntheticEvents(false);
    assert.equal(own.defaultPrevented, true);
    assert.equal(pageSaw, 0);
    assert.deepEqual(asked.filter((m) => m.type === 'outgoing').map((m) => m.threadId), [idB]);

    // 7. Close B and reopen it with the same rows: the poll sees the detached #main and clears the stale signature
    // (main.js, the isConnected branch), so B mounts again within the usual ~1 s instead of the 10 s stale wait.
    doc.querySelector('#main').remove();
    await advance(600);
    composer = openChat('Other Chat', ['hello']);
    await advance(2000);
    assert.equal(mounts, 3);
    assert.equal(threadIds().at(-1), idB);

    // 8. Enter on a focused message (Reply with text in the box): a synthetic one is held, the user's own one
    // translates the box for B instead of letting WhatsApp send the Hangul.
    asked.length = 0;
    assert.equal(rowEnter(composer).defaultPrevented, true);
    await flush();
    assert.deepEqual(asked.filter((m) => m.type === 'outgoing'), []);
    _trustSyntheticEvents(true);
    const fromRow = rowEnter(composer);
    await flush();
    _trustSyntheticEvents(false);
    assert.equal(fromRow.defaultPrevented, true);
    assert.equal(rowSaw, 0);
    assert.deepEqual(asked.filter((m) => m.type === 'outgoing').map((m) => [m.threadId, m.korean]), [[idB, '안녕']]);

    // 9. Escape while translating is protly's cancel: neither its keydown nor its keyup reaches WhatsApp's own early
    // listener, so a quote-reply survives. With nothing to cancel, Escape is WhatsApp's again.
    const esc = (type) => {
      const e = new win.KeyboardEvent(type, { key: 'Escape', code: 'Escape', bubbles: true, cancelable: true });
      composer.dispatchEvent(e);
      return e;
    };
    _trustSyntheticEvents(true);
    assert.equal(esc('keydown').defaultPrevented, true);
    esc('keyup');
    await flush();
    assert.equal(pageEsc, 0);
    await advance(300);
    esc('keydown');
    esc('keyup');
    _trustSyntheticEvents(false);
    assert.equal(pageEsc, 2);

    // 10. Alt+Z while translating is protly's undo and is swallowed; with nothing to undo it is the page's.
    const altZ = () => {
      const e = new win.KeyboardEvent('keydown', { key: 'z', code: 'KeyZ', altKey: true, bubbles: true, cancelable: true });
      composer.dispatchEvent(e);
      return e;
    };
    _trustSyntheticEvents(true);
    const before = asked.filter((m) => m.type === 'outgoing').length;
    assert.equal(hangulEnter(composer).defaultPrevented, true);
    await flush();
    assert.equal(asked.filter((m) => m.type === 'outgoing').length, before + 1);
    assert.equal(altZ().defaultPrevented, true);
    await advance(300); // the undo's write lands
    assert.equal(altZ().defaultPrevented, false);
    _trustSyntheticEvents(false);
  } finally {
    _trustSyntheticEvents(false);
    mock.timers.reset();
  }
});
