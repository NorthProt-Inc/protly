// Instagram as the content script mounts it: main.js start() finds the thread and mounts outgoing.js. One mount per
// test file (node --test runs each file in its own process): every start() adds its own listeners.
import { JSDOM } from 'jsdom';

const PAGE = `<body>
  <nav><a href="/me"><img alt="me's profile picture"></a></nav>
  <div role="main"><form><div role="textbox" contenteditable="true"></div></form></div>
</body>`;

// outgoing(msg): the reply to a billed 'outgoing' or 'polish' call; by default it never answers.
export async function mountInstagram({ outgoing = () => new Promise(() => {}) } = {}) {
  const win = new JSDOM(PAGE, { url: 'https://www.instagram.com/direct/t/123/' }).window;
  for (const k of ['window', 'document', 'location', 'MutationObserver', 'Option', 'Node', 'getComputedStyle']) {
    globalThis[k] = k === 'window' ? win : win[k];
  }
  const asked = [];
  let mounted;
  const isMounted = new Promise((r) => { mounted = r; });
  globalThis.chrome = {
    storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
    runtime: {
      id: 'protly',
      getURL: (p) => `chrome-extension://protly/${p}`,
      onMessage: { addListener: () => mounted(), removeListener() {} }, // outgoing.js registers its Alt+T listener
      sendMessage: (msg) => {
        asked.push(msg);
        if (msg.type === 'getThread') return Promise.resolve({ ok: true, data: { enabled: true, outputLang: 'auto', otherTarget: 'ko', pastMode: 'replace', newMode: 'below', memo: '' } });
        if (msg.type === 'outgoing' || msg.type === 'polish') return outgoing(msg);
        return Promise.resolve({ ok: true, data: true });
      },
    },
  };
  globalThis.fetch = async () => ({ ok: false, status: 404 }); // fonts: the monospace fallback
  const realSetInterval = globalThis.setInterval;
  globalThis.setInterval = (f, ms) => realSetInterval(f, ms).unref(); // the path poll must not keep the test alive
  const { start } = await import('../src/content/instagram.js');
  await start();
  await isMounted; // an empty thread is accepted after about 1 s
  const composer = win.document.querySelector('div[role="textbox"]');
  Object.defineProperty(composer, 'innerText', { get: () => composer.textContent }); // jsdom has no layout text
  return { win, asked, composer };
}
