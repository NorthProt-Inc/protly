// WhatsApp Web as mounted by the content script, from a title selector miss to a mounted thread. One start() per
// file: every start() adds its own hooks, guard and poll loop.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const PAGE = `<body><div id="main"><header><div class="title-slot"></div></header>
  <div data-testid="conversation-panel-messages"></div>
  <footer><div><div contenteditable="true" role="textbox" data-lexical-editor="true"></div></div></footer>
</div></body>`;

const flush = () => new Promise((r) => setImmediate(r)); // setImmediate is not mocked

test('WhatsApp: Hangul Enter is held before and after the thread mounts; a title miss shows the badge', async () => {
  const win = new JSDOM(PAGE, { url: 'https://web.whatsapp.com/' }).window;
  for (const k of ['window', 'document', 'location', 'MutationObserver', 'Option', 'Node', 'getComputedStyle']) {
    globalThis[k] = k === 'window' ? win : win[k];
  }
  const asked = [];
  let mounted = false;
  globalThis.chrome = {
    storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
    runtime: {
      id: 'protly',
      getURL: (p) => `chrome-extension://protly/${p}`,
      onMessage: { addListener: () => { mounted = true; }, removeListener() {} }, // outgoing.js's Alt+T listener
      sendMessage: (msg) => {
        asked.push(msg);
        if (msg.type === 'getThread') return Promise.resolve({ ok: true, data: { enabled: true, outputLang: 'auto', otherTarget: 'ko', pastMode: 'replace', newMode: 'below', memo: '' } });
        if (msg.type === 'outgoing' || msg.type === 'polish') return new Promise(() => {}); // billed: never answers
        return Promise.resolve({ ok: true, data: true });
      },
    },
  };
  globalThis.fetch = async () => ({ ok: false, status: 404 }); // fonts: the monospace fallback

  const composer = win.document.querySelector('footer [role="textbox"]');
  // jsdom implements neither: main.js's guard reads isContentEditable (see src/generic/target.js), and there is no
  // layout text.
  Object.defineProperty(composer, 'isContentEditable', { value: true });
  Object.defineProperty(composer, 'innerText', { get: () => composer.textContent });
  let pageSaw = 0;
  composer.addEventListener('keydown', () => { pageSaw++; }); // WhatsApp's own send handler sits here
  const hangulEnter = () => {
    composer.textContent = '안녕';
    const e = new win.KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
    composer.dispatchEvent(e);
    return e;
  };

  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  try {
    const { start } = await import('../src/content/whatsapp/site.js');
    await start();

    // 1. #main but no title: the id is wa-untitled and the guard holds the Enter.
    let e = hangulEnter();
    assert.equal(e.defaultPrevented, true);
    assert.equal(pageSaw, 0);

    // 2. The wait gives up after about 10 s and says why.
    for (let i = 0; i < 40; i++) { mock.timers.tick(300); await flush(); }
    assert.ok(asked.some((m) => m.type === 'badge' && m.reason === 'WhatsApp thread not found'));
    assert.equal(mounted, false);

    // 3. The title shows up: the poll sees a new id (wa-untitled -> wa-<hash>) and mounts the thread.
    const title = win.document.createElement('span');
    title.dataset.testid = 'conversation-info-header-chat-title';
    title.textContent = 'Test Partner';
    win.document.querySelector('.title-slot').append(title);
    for (let i = 0; i < 10; i++) { mock.timers.tick(300); await flush(); }
    assert.equal(mounted, true);
    assert.ok(asked.some((m) => m.type === 'getThread' && /^wa-[0-9a-f]{14}$/.test(m.threadId)));

    // 4. The mounted outgoing handler holds a synthetic Enter and bills nothing.
    asked.length = 0;
    e = hangulEnter();
    await flush();
    assert.equal(e.defaultPrevented, true);
    assert.equal(pageSaw, 0);
    assert.deepEqual(asked.filter((m) => m.type === 'outgoing' || m.type === 'polish'), []);
  } finally {
    mock.timers.reset();
  }
});
