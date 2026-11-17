// Smoke check: does headless Chromium load the unpacked extension and start its service worker?
const { chromium } = require('/opt/node-tools/node_modules/playwright');
(async () => {
  const dir = process.argv[2];
  const ctx = await chromium.launchPersistentContext('', { headless: true, channel: 'chromium', args: [`--disable-extensions-except=${dir}`, `--load-extension=${dir}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker', { timeout: 10000 });
  console.log('sw', sw.url());
  console.log(await sw.evaluate(() => typeof chrome.runtime.connectNative));
  await ctx.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
