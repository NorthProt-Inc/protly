// Classic content script for WhatsApp Web. Content scripts cannot be ES modules, so load the real entry dynamically.
(async () => {
  try {
    const { start } = await import(chrome.runtime.getURL('src/content/whatsapp/site.js'));
    await start();
  } catch (e) {
    console.error('[protly] WhatsApp part failed to load', e);
  }
})();
