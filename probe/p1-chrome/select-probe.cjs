// Does the writers' select-all (selectAllChildren + 60 ms) cover the whole Lexical draft? For several draft shapes,
// types the draft, selects all the way setComposerText does, then reports: the DOM selection's length vs the box,
// Lexical's own selection (anchor/focus offsets, text length it covers), and what execCommand('insertText') of a
// one-line and a three-line text leaves (DOM text, synthetic). No extension involved.
// Usage: node probe/p1-chrome/select-probe.cjs <editors.bundle.js>
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const fs = require('node:fs');

const bundle = fs.readFileSync(process.argv[2], 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Each shape: keys between and after the lines.
const SHAPES = {
  'lines': { brk: 'Shift+Enter', lines: ['가나', '다라', '마바'], tail: [] },
  'lines+trailing-break': { brk: 'Shift+Enter', lines: ['가나', '다라', '마바'], tail: ['Shift+Enter'] },
  'paras': { brk: 'Enter', lines: ['가나', '다라', '마바'], tail: [] },
  'paras+empty-last': { brk: 'Enter', lines: ['가나', '다라', '마바'], tail: ['Enter'] },
  'one+trailing-break': { brk: 'Shift+Enter', lines: ['가나'], tail: ['Shift+Enter'] },
  'blank-line-inside': { brk: 'Shift+Enter', lines: ['가나', '', '다라'], tail: [] },
};

(async () => {
  const b = await chromium.launch({ headless: true });
  for (const ed of ['lexical-rich', 'lexical-plain']) for (const [shape, s] of Object.entries(SHAPES)) for (const write of ['X1', 'A1\nB2\nC3']) {
    const p = await b.newPage();
    await p.setContent(`<!doctype html><meta charset="utf-8"><body><div id="ed" contenteditable="true"></div><script>${bundle}</script><script>__probeMount(${JSON.stringify(ed)}, document.getElementById('ed'));</script></body>`);
    await p.click('#ed');
    for (const [i, l] of s.lines.entries()) { if (i) await p.keyboard.press(s.brk); if (l) await p.keyboard.insertText(l); }
    for (const k of s.tail) await p.keyboard.press(k);
    await sleep(50);
    const r = await p.evaluate(async (text) => {
      const el = document.getElementById('ed');
      el.focus();
      const sel = document.getSelection();
      sel.selectAllChildren(el);
      await new Promise((res) => setTimeout(res, 60));
      const domSel = sel.toString().length;
      const box = el.innerText.length;
      let lex = null;
      window.__lexical.getEditorState().read(() => {
        const s = window.__lexicalSel();
        lex = s ? { covers: s.getTextContent().length, total: window.__lexicalRootText().length } : null;
      });
      el.focus();
      document.execCommand('insertText', false, text);
      await new Promise((res) => setTimeout(res, 300));
      return { domSel, box, lex, after: el.innerText };
    }, write);
    console.log(JSON.stringify({ ed, shape, write, ...r }));
    await p.close();
  }
  await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
