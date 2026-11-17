// Minimal write probe, no extension: for each editor, type a 3-line draft, then do exactly what the extension's
// writers do (src/content/dom.js setComposerText and src/generic/writer.js writeBox: focus, selectAllChildren, wait
// 60 ms, execCommand('insertText', false, text)) with a 3-line text, and print the DOM text and the editor model
// (JSON, synthetic text only) at 0, 50 and 500 ms. Also prints what Shift+Enter and Enter typing produce.
// Usage: node probe/p1-chrome/write-probe.cjs <editors.bundle.js>
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const fs = require('node:fs');

const bundle = fs.readFileSync(process.argv[2], 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDS = (process.env.EDS || 'ce,lexical-rich,lexical-plain,draft,slate').split(',');

(async () => {
  const b = await chromium.launch({ headless: true });
  for (const ed of EDS) {
    for (const brk of ['Enter', 'Shift+Enter']) {
      for (const write of ['A1\nB2\nC3', 'A1\n\nB2\n\nC3']) {
        const p = await b.newPage();
        const tag = ed === 'ce' ? '<div id="ed" contenteditable="true"></div>'
          : ed.startsWith('lexical') ? '<div id="ed" contenteditable="true"></div>' : '<div id="edwrap"></div>';
        await p.setContent(`<!doctype html><meta charset="utf-8"><body>${tag}<script>window.__errs=[];addEventListener('error',(e)=>__errs.push(String(e.message)));</script><script>${bundle}</script><script>
          if (${JSON.stringify(ed)} === 'ce') window.__probe = { model: () => null };
          else __probeMount(${JSON.stringify(ed)}, document.getElementById(${JSON.stringify(ed.startsWith('lexical') ? 'ed' : 'edwrap')}));
        </script></body>`);
        const sel = (await p.$('#ed')) ? '#ed' : '#edwrap [contenteditable="true"]';
        await p.waitForSelector(sel);
        await p.click(sel);
        for (const [i, l] of ['가나', '다라', '마바'].entries()) { if (i) await p.keyboard.press(brk); await p.keyboard.insertText(l); }
        await sleep(50);
        const state = () => p.evaluate((s) => {
          const el = document.querySelector(s);
          let model = null;
          try { model = window.__probe.model?.() ?? null; } catch (e) { model = 'ERR ' + e.message; }
          return { dom: el ? el.innerText : '(no editable: ' + (document.querySelector('#edwrap')?.innerText ?? '') + ')', model, errors: window.__errs.length, errMsg: window.__errs.slice(0, 1).map((m) => m.slice(0, 160)) };
        }, sel);
        const typed = await state();
        const res = [];
        await p.evaluate(async ({ s, text }) => {
          const el = document.querySelector(s);
          el.focus();
          document.getSelection().selectAllChildren(el);
          await new Promise((r) => setTimeout(r, 60));
          el.focus();
          window.__ret = document.execCommand('insertText', false, text);
        }, { s: sel, text: write });
        res.push(['0', await state()]);
        await sleep(50); res.push(['50', await state()]);
        await sleep(450); res.push(['500', await state()]);
        console.log(JSON.stringify({ ed, brk, write, typed, after: res }));
        await p.close();
      }
    }
  }
  await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
