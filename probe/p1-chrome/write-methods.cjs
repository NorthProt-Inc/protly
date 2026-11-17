// Which write method keeps line breaks in each editor? (Fix-direction evidence, no extension code changed.)
// After typing a 3-line Korean draft and selecting all (selectAllChildren + 60 ms, as the writers do), each method
// writes "A1\nB2\nC3" or "A1\n\nB2\n\nC3"; prints DOM innerText and the editor model at 500 ms (synthetic text).
// Methods: exec (today: execCommand insertText with the whole text), lines (execCommand insertText per line with
// execCommand insertLineBreak between), paste (a synthetic ClipboardEvent 'paste' with text/plain; falls back to
// exec when nothing handled it), paras (per line, execCommand insertParagraph between).
// Usage: node probe/p1-chrome/write-methods.cjs <editors.bundle.js>
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const fs = require('node:fs');

const bundle = fs.readFileSync(process.argv[2], 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDS = ['ce', 'lexical-rich', 'lexical-plain', 'draft', 'slate'];
const METHODS = ['exec', 'lines', 'paras', 'paste'];

(async () => {
  const b = await chromium.launch({ headless: true });
  for (const ed of EDS) for (const method of METHODS) for (const write of ['A1\nB2\nC3', 'A1\n\nB2\n\nC3']) {
    const p = await b.newPage();
    const tag = ed === 'ce' || ed.startsWith('lexical') ? '<div id="ed" contenteditable="true"></div>' : '<div id="edwrap"></div>';
    await p.setContent(`<!doctype html><meta charset="utf-8"><body>${tag}<script>window.__errs=[];addEventListener('error',(e)=>__errs.push(String(e.message)));</script><script>${bundle}</script><script>
      if (${JSON.stringify(ed)} === 'ce') window.__probe = { model: () => null };
      else __probeMount(${JSON.stringify(ed)}, document.getElementById(${JSON.stringify(ed.startsWith('lexical') ? 'ed' : 'edwrap')}));
    </script></body>`);
    const sel = (await p.$('#ed')) ? '#ed' : '#edwrap [contenteditable="true"]';
    await p.waitForSelector(sel);
    await p.click(sel);
    for (const [i, l] of ['가나', '다라', '마바'].entries()) { if (i) await p.keyboard.press('Shift+Enter'); await p.keyboard.insertText(l); }
    await sleep(50);
    await p.evaluate(async ({ s, text, method }) => {
      const el = document.querySelector(s);
      el.focus();
      document.getSelection().selectAllChildren(el);
      await new Promise((r) => setTimeout(r, 60));
      el.focus();
      if (method === 'exec') document.execCommand('insertText', false, text);
      else if (method === 'lines' || method === 'paras') {
        text.split('\n').forEach((l, i) => {
          if (i) document.execCommand(method === 'lines' ? 'insertLineBreak' : 'insertParagraph');
          if (l) document.execCommand('insertText', false, l);
        });
      } else {
        const dt = new DataTransfer();
        dt.setData('text/plain', text);
        const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
        el.dispatchEvent(ev);
        window.__pasteHandled = ev.defaultPrevented;
        if (!ev.defaultPrevented) document.execCommand('insertText', false, text);
      }
    }, { s: sel, text: write, method });
    await sleep(500);
    const st = await p.evaluate((s) => {
      const el = document.querySelector(s);
      let model = null;
      try { model = window.__probe.model?.() ?? null; } catch (e) { model = `ERR ${e.message}`; }
      return { dom: el ? el.innerText : '(editable gone)', model, errors: window.__errs.length, pasteHandled: window.__pasteHandled ?? null };
    }, sel);
    console.log(JSON.stringify({ ed, method, write, ...st }));
    await p.close();
  }
  await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
