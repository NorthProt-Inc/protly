// Does a CDP key press of Alt+T reach chrome.commands (manifest "run", suggested Alt+T) in headless Chromium?
// If yes the harness could use the real shortcut; if not it must emulate background.js route() (it does).
// Usage: node probe/p1-chrome/real-alt-t.cjs <extDir>
const { chromium } = require('/opt/node-tools/node_modules/playwright');

(async () => {
  const EXT = process.argv[2];
  const ctx = await chromium.launchPersistentContext('', { headless: true, channel: 'chromium', args: [`--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`] });
  await ctx.route('https://www.instagram.com/**', (r) => r.fulfill({ contentType: 'text/html; charset=utf-8', body: '<!doctype html><meta charset="utf-8"><textarea id="ed"></textarea>' }));
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  await sw.evaluate(() => {
    globalThis.__cmds = 0;
    chrome.commands.onCommand.addListener(() => { globalThis.__cmds++; });
  });
  const cmds = await sw.evaluate(() => chrome.commands.getAll().then((a) => a.map((c) => `${c.name}=${c.shortcut || '(none)'}`)));
  const p = await ctx.newPage();
  await p.goto('https://www.instagram.com/protly-probe/');
  await p.click('#ed');
  await p.keyboard.insertText('가나');
  await p.keyboard.press('Alt+t');
  await p.keyboard.press('Alt+KeyT');
  await new Promise((r) => setTimeout(r, 1000));
  console.log(JSON.stringify({ commands: cmds, onCommandFired: await sw.evaluate(() => globalThis.__cmds) }));
  await ctx.close();
})().catch((e) => { console.error(e); process.exit(1); });
