// Classic content script for WhatsApp Web, run at document_start. Content scripts cannot be ES modules, so the real
// entry is loaded dynamically once the page is parsed.
//
// Key relay: WhatsApp adds its own window key listeners while it loads, so a listener protly adds later runs after
// them and cannot stop them (Escape cancelled a quote-reply although protly blocked it; live check 2026-11-08).
// These two go on window before any page script runs; protly's key handlers join them via globalThis.protlyEarlyKeys.
(() => {
  const relays = { keydown: new Set(), keyup: new Set() };
  for (const [type, fns] of Object.entries(relays)) {
    window.addEventListener(type, (e) => { for (const f of fns) f(e); }, true);
  }
  globalThis.protlyEarlyKeys = relays;
})();

(async () => {
  try {
    if (document.readyState === 'loading') {
      await new Promise((r) => document.addEventListener('DOMContentLoaded', r, { once: true }));
    }
    const { start } = await import(chrome.runtime.getURL('src/content/whatsapp/site.js'));
    await start();
  } catch (e) {
    console.error('[protly] WhatsApp part failed to load', e);
  }
})();
