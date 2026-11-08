// WhatsApp Web as mounted by the content script: a title selector miss, a late title, a chat switch (WhatsApp
// replaces #main), a real Enter, and closing and reopening a chat. One start() per file: every start() adds its own
// hooks, guard and poll loop.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

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
  const threadIds = () => asked.filter((m) => m.type === 'getThread').map((m) => m.threadId);

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
  } finally {
    _trustSyntheticEvents(false);
    mock.timers.reset();
  }
});
