// P1 probe (diagnosis only, never merged): does Translate cover the whole multi-line draft in the Chrome extension?
//
// Loads the unpacked extension in Chromium (Playwright, channel 'chromium', new headless), serves local pages under
// the real hostnames with context.route (www.instagram.com, web.whatsapp.com, mail.google.com), so the manifest's
// content scripts run on them. Real editors (Lexical rich/plain, Draft.js, Slate) come from editors.bundle.js.
// The native host is faked in the service worker: chrome.runtime.connectNative returns a port that answers every
// API body with a translation that keeps the draft's line structure, nonblank line k -> "EN<k>".
// Alt+T is sent the way background.js route() does it (tabs.sendMessage command, else inject dist/generic.js and
// call run), because a CDP key event does not reach chrome.commands (checked separately: see realAltT).
//
// Output: one JSON line per trial (lengths, counts, booleans, timings; never field text) to OUT.
// Usage: node probe/p1-chrome/harness.cjs <extDir> <editors.bundle.js> <out.jsonl> [filter-json]
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const fs = require('node:fs');

const [EXT, BUNDLE, OUT, FILTER] = process.argv.slice(2);
const filter = FILTER ? JSON.parse(FILTER) : {};
const bundle = fs.readFileSync(BUNDLE, 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Synthetic Korean lines (no brackets, no "xx:" prefixes, no names).
const KO = [
  '오늘 진짜 재밌었어 고마워',
  '다음에는 내가 밥 살게 ㅋㅋ',
  '근데 그 영화 결말이 좀 이상하지 않았어',
  '주말에 시간 되면 같이 산책 가자',
  '아 그리고 사진 보내줘서 고마워 ㅠㅠ',
  '내일 아침에 일찍 일어나야 해서 먼저 잘게',
  '건강 잘 챙기고 푹 쉬어',
];

function draftLines(n, lineMode) {
  const lines = KO.slice(0, n);
  return lineMode === 'blank' || lineMode === 'paste-blank' ? lines.flatMap((l, i) => (i ? ['', l] : [l])) : lines;
}

// ---------- pages ----------
const editorTag = (ed) => {
  if (ed === 'textarea') return '<textarea id="ed" rows="12" cols="60"></textarea>';
  if (ed === 'ce') return '<div id="ed" contenteditable="true" role="textbox" style="min-height:120px;border:1px solid #888"></div>';
  if (ed.startsWith('lexical')) return '<div id="ed" contenteditable="true" style="min-height:120px;border:1px solid #888"></div>';
  return '<div id="edwrap" style="min-height:120px;border:1px solid #888"></div>';
};
const mountScript = (ed) => {
  if (ed === 'textarea') return `window.__probe={kind:'textarea',model:()=>document.getElementById('ed').value.split('\\n')};`;
  if (ed === 'ce') return `window.__probe={kind:'ce',model:()=>document.getElementById('ed').innerText.replace(/\\n$/,'').split('\\n')};`;
  if (ed.startsWith('lexical')) return `__probeMount(${JSON.stringify(ed)}, document.getElementById('ed'));`;
  return `__probeMount(${JSON.stringify(ed)}, document.getElementById('edwrap'));`;
};
const page = (body, ed) => `<!doctype html><html><head><meta charset="utf-8"><title>probe</title></head><body>${body}
<script src="/__probe/editors.js"></script><script>${mountScript(ed)}</script></body></html>`;

function htmlFor(url) {
  const u = new URL(url);
  const ed = u.searchParams.get('ed') || 'ce';
  if (u.hostname === 'www.instagram.com' && u.pathname.startsWith('/direct/t/')) {
    // Instagram thread as tests/instagram-mount.js shapes it: viewer avatar outside main, composer in a form.
    const tag = editorTag(ed).replace('<div id="ed"', '<div id="ed" role="textbox"');
    return page(`<nav><a href="/me"><img alt="me's profile picture"></a></nav><div role="main"><form>${tag}</form></div>`, ed);
  }
  if (u.hostname === 'www.instagram.com') { // /protly-probe/: no thread, so Alt+T takes the generic path
    return page(`<h1>generic</h1><div>${editorTag(ed)}</div>`, ed);
  }
  if (u.hostname === 'web.whatsapp.com') { // tests/fixtures/whatsapp-chat.html without message rows
    const tag = editorTag(ed).replace('<div id="ed"', '<div id="ed" role="textbox" aria-label="Type a message to Test Partner"');
    return page(`<div id="side"></div><div id="main"><header><div><span data-testid="conversation-info-header-chat-title">Test Partner</span></div></header>
<div data-testid="conversation-panel-messages"></div><footer><div>${tag}</div></footer></div>`, ed);
  }
  if (u.hostname === 'mail.google.com') { // tests/fixtures/gmail.html: inline reply body is a plain contenteditable
    const sig = u.searchParams.get('sig') || 'none';
    const inner = {
      none: '<br>',
      flat: '<br><div><br></div><span class="gmail_signature_prefix">-- </span><br><div class="gmail_signature" data-smartmail="gmail_signature">Sig</div>',
      wrapped: '<div dir="ltr"><br><div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">Sig</div></div>',
      quote: '<br><div class="gmail_quote">On Monday someone wrote: old text</div>',
    }[sig];
    return `<!doctype html><html><head><meta charset="utf-8"></head><body>
<a aria-label="Google Account: Viewer Name (viewer@example.com)" href="#"></a>
<div role="main"><div role="list"></div><div class="reply">
<div id="ed" role="textbox" aria-label="Message Body" contenteditable="true" g_editable="true" aria-multiline="true" style="min-height:120px;border:1px solid #888">${inner}</div>
<table role="group"><tbody><tr><td><div role="button" data-tooltip="Send (Ctrl-Enter)">Send</div></td><td></td></tr></tbody></table>
</div></div>
<script>window.__probe={kind:'gmail',model:()=>null};</script></body></html>`;
  }
  return '<!doctype html><p>unknown</p>';
}

// ---------- service worker fake ----------
async function installFake(sw) {
  await sw.evaluate(() => {
    if (globalThis.__probeFake) return;
    globalThis.__probeFake = true;
    globalThis.__calls = [];
    globalThis.__delay = 300;
    globalThis.__mode = 'keep'; // 'keep': EN<k> per nonblank line
    const draftOf = (content) => {
      const i = content.lastIndexOf('DRAFT:\n');
      return i < 0 ? null : content.slice(i + 'DRAFT:\n'.length);
    };
    chrome.runtime.connectNative = () => {
      const msgL = [];
      return {
        onMessage: { addListener: (f) => msgL.push(f) },
        onDisconnect: { addListener: () => {} },
        disconnect: () => {},
        postMessage: (msg) => {
          if (msg.ping) { setTimeout(() => msgL.forEach((f) => f({ id: msg.id, ping: { ok: true } })), 0); return; }
          const content = msg.body?.messages?.[0]?.content ?? '';
          let json;
          const draft = draftOf(content);
          if (content.includes('MESSAGES TO TRANSLATE')) json = { items: [] };
          else if (draft == null) json = { memo: '' };
          else {
            let k = 0;
            const out = draft.split('\n').map((l) => (l.trim() ? `EN${++k}` : l)).join('\n');
            globalThis.__calls.push({ t: Date.now(), len: draft.length, lines: draft.split('\n').length, nonblank: k, draft, out, max_tokens: msg.body.max_tokens });
            json = { translation: out, back_translation: 'BT', lang: 'en' };
          }
          const reply = { id: msg.id, status: 200, body: { stop_reason: 'end_turn', content: [{ type: 'text', text: JSON.stringify(json) }], usage: { input_tokens: 1, output_tokens: 1 } } };
          setTimeout(() => msgL.forEach((f) => f(reply)), globalThis.__delay);
        },
      };
    };
  });
}

// background.js route(): adapter first, then the generic bundle.
async function altT(sw, url) {
  return sw.evaluate(async (u) => {
    // tabs.query({url}) needs host permission (Instagram only); the harness keeps one probe tab open: the newest.
    const tabs = await chrome.tabs.query({});
    const tab = tabs.sort((a, b) => b.id - a.id)[0];
    if (!tab) return 'no-tab';
    let a = null;
    try { a = await chrome.tabs.sendMessage(tab.id, { type: 'command' }, { frameId: 0 }); } catch {}
    if (a?.handled) return 'adapter';
    await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, files: ['dist/generic.js'] });
    // Not awaited: run() resolves only after the write; the harness polls instead.
    chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, func: (x) => globalThis[Symbol.for('protly')].run(x), args: [{ source: 'command' }] });
    return 'generic';
  }, url);
}

// Text of protly's cards and toasts (closed shadow roots), through CDP's pierce.
async function protlyUi(cdp) {
  const { root } = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
  const texts = [];
  const walk = (n, inShadow, acc) => {
    if (n.nodeType === 3 && inShadow) acc.push(n.nodeValue);
    for (const c of n.children || []) walk(c, inShadow, acc);
    for (const s of n.shadowRoots || []) { const a = []; walk(s, true, a); texts.push(a.join(' ')); }
    if (n.contentDocument) walk(n.contentDocument, inShadow, acc);
  };
  walk(root, false, []);
  return texts.filter((t) => t.trim() && !t.includes('Suggest memo') && !t.includes('protly thread settings')).join(' | ');
}
const KNOWN = ['Could not write', 'changed while translating', 'draft changed', 'Translation failed', 'Too long', 'Nothing to', 'Focus moved', 'not recognised', 'BT', 'Translating', 'Polishing', 'Press Enter again'];
const classifyUi = (s) => KNOWN.filter((k) => s.includes(k)).join(',') || (s.trim() ? 'other' : 'none');

// ---------- input ----------
async function typeDraft(p, cdp, surface, lines, lineMode, ime) {
  const ig = surface.startsWith('ig:') || surface.startsWith('wa:'); // Enter sends there: lines break with Shift+Enter
  const brk = async () => {
    if (lineMode === 'shift' || ig) { await p.keyboard.press('Shift+Enter'); } else { await p.keyboard.press('Enter'); }
  };
  if (lineMode.startsWith('paste')) {
    const text = lines.join('\n');
    await p.evaluate((t) => {
      const el = document.activeElement;
      const dt = new DataTransfer();
      dt.setData('text/plain', t);
      const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
      el.dispatchEvent(ev);
      if (!ev.defaultPrevented) document.execCommand('insertText', false, t); // a box with no paste handler
    }, text);
    return;
  }
  if (lineMode === 'trail') {
    // like para, plus one more line break after the last line (the caret ends on an empty line)
    for (let i = 0; i < lines.length; i++) { if (i) await brk(); await cdp.send('Input.insertText', { text: lines[i] }); }
    await brk();
    return;
  }
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (i) await brk();
    if (!l) continue;
    if (ime && l.length > 1) {
      await cdp.send('Input.insertText', { text: l.slice(0, -1) });
      // last syllable through an IME composition (jamo steps are approximated by the syllable itself)
      const last = l.slice(-1);
      await cdp.send('Input.imeSetComposition', { text: last, selectionStart: 1, selectionEnd: 1 });
      const final = i === lines.length - 1;
      if (!final) await cdp.send('Input.insertText', { text: last }); // commit
      // the last line's last syllable stays composing: the trigger arrives mid-composition
    } else {
      await cdp.send('Input.insertText', { text: l });
    }
  }
}

async function placeCursor(p, cursor) {
  if (cursor === 'end') return;
  await p.keyboard.press('Control+Home');
  await p.keyboard.press('ArrowDown');
  await p.keyboard.press('End');
  if (cursor === 'middle') { for (let i = 0; i < 4; i++) await p.keyboard.press('ArrowLeft'); return; }
  if (cursor === 'selection') await p.keyboard.press('Shift+Home');
}

async function readState(p) {
  return p.evaluate(() => {
    const el = document.getElementById('ed') || document.querySelector('#edwrap [contenteditable="true"]');
    const dom = el ? (el.tagName === 'TEXTAREA' ? el.value : el.innerText) : '';
    let model = null;
    try { model = window.__probe?.model?.() ?? null; } catch (e) { model = ['ERR']; }
    return { dom, model, composing: !!window.__composing };
  });
}

const nonblank = (s) => s.split('\n').map((l) => l.trim()).filter(Boolean);

function surfaceUrl(s) {
  const [site, ed] = s.split(':');
  if (site === 'ig') return `https://www.instagram.com/direct/t/123/?ed=${ed}`;
  if (site === 'wa') return `https://web.whatsapp.com/?ed=${ed}`;
  if (site === 'gm') return `https://mail.google.com/mail/u/0/?sig=${ed}`;
  return `https://www.instagram.com/protly-probe/?ed=${ed}`;
}

async function waitMounted(p, site) {
  if (site === 'gen') return true;
  const fn = site === 'gm'
    ? () => !!document.querySelector('.pl-g-btn')
    : () => [...document.body.children].some((e) => e.style?.bottom === '96px');
  try { await p.waitForFunction(fn, null, { timeout: 15000 }); return true; } catch { return false; }
}

async function trial(ctx, sw, cfg) {
  const { surface, n, lineMode, cursor, ime, trigger, delay, rep } = cfg;
  const [site] = surface.split(':');
  const url = surfaceUrl(surface);
  const p = await ctx.newPage();
  const cdp = await ctx.newCDPSession(p);
  const rec = { ...cfg };
  try {
    await p.addInitScript(() => {
      window.__composing = false;
      document.addEventListener('compositionstart', () => { window.__composing = true; }, true);
      document.addEventListener('compositionend', () => { window.__composing = false; }, true);
    });
    await p.goto(url);
    rec.mounted = await waitMounted(p, site);
    await sw.evaluate((d) => { globalThis.__calls = []; globalThis.__delay = d; }, delay);
    const target = (await p.$('#ed')) ? '#ed' : '#edwrap [contenteditable="true"]';
    await p.waitForSelector(target);
    await p.click(target);
    if (site === 'gm') await p.keyboard.press('Control+Home');
    const lines = draftLines(n, lineMode);
    const want = lines.join('\n');
    await typeDraft(p, cdp, surface, lines, lineMode, ime);
    await sleep(80);
    await placeCursor(p, cursor);
    await sleep(40);
    const before = await readState(p);
    rec.before = {
      domLen: before.dom.length, domLines: before.dom.split('\n').length, domNonblank: nonblank(before.dom).length,
      domHoldsAll: nonblank(want).every((l) => before.dom.includes(l.slice(0, -1))),
      modelBlocks: before.model ? before.model.length : null,
      modelNonblank: before.model ? nonblank(before.model.join('\n')).length : null,
      composing: before.composing,
      typedOk: (before.model ? nonblank(before.model.join('\n')).length : nonblank(before.dom).length) >= nonblank(want).length,
      breaksInDom: (before.dom.match(/\n/g) || []).length,
    };
    if (process.env.DEBUG) console.error('BEFORE', await p.evaluate(() => (document.getElementById('ed') || document.querySelector('#edwrap [contenteditable]')).outerHTML));
    await p.evaluate(() => {
      // shape of the box every 10 ms, only on change: lines, EN markers, Hangul yes/no
      const el = document.getElementById('ed') || document.querySelector('#edwrap [contenteditable="true"]');
      const t0 = performance.now();
      let last = '';
      window.__tl = [];
      const tick = () => {
        const d = el.tagName === 'TEXTAREA' ? el.value : el.innerText;
        const sh = `${d.split('\n').length}L/${(d.match(/EN\d+/g) || []).length}M/${/[가-힯]/.test(d) ? 'H' : '-'}`;
        if (sh !== last) { window.__tl.push(`${Math.round(performance.now() - t0)}:${sh}`); last = sh; }
      };
      tick();
      window.__tlTimer = setInterval(tick, 10);
    });
    const t0 = Date.now();
    if (trigger === 'enter') { await p.keyboard.press('Enter'); rec.route = 'enter'; }
    else rec.route = await altT(sw, url);
    // wait for the API call, then for the box to change
    let calls = [];
    for (let i = 0; i < 100; i++) {
      calls = await sw.evaluate(() => globalThis.__calls);
      if (calls.length) break;
      await sleep(30);
    }
    rec.calls = calls.length;
    rec.callMs = calls.length ? calls[0].t - t0 : null;
    let after = null;
    if (calls.length) {
      const c = calls[0];
      const typed = want; // what was typed (paste or keys)
      rec.sent = {
        len: c.len, lines: c.lines, nonblank: c.nonblank, max_tokens: c.max_tokens,
        exactTyped: c.draft === typed,
        sameNonblank: JSON.stringify(nonblank(c.draft)) === JSON.stringify(nonblank(typed)),
        lostLines: nonblank(typed).length - c.nonblank,
        blankLinesTyped: typed.split('\n').filter((l) => !l.trim()).length,
        blankLinesSent: c.draft.split('\n').filter((l) => !l.trim()).length,
      };
      // Fixed settle: the reply delay, the writer's select settle and verify (60 + 300 ms), a restore, margin.
      await sleep(delay + 1300);
      after = await readState(p);
      rec.timeline = await p.evaluate(() => window.__tl.splice(0));
      after = after || (await readState(p));
      const out = c.out;
      rec.after = {
        domExact: after.dom === out,
        domExactTrimEnd: after.dom.replace(/\n+$/, '') === out,
        domNonblankEq: JSON.stringify(nonblank(after.dom)) === JSON.stringify(nonblank(out)),
        domLines: after.dom.split('\n').length, outLines: out.split('\n').length,
        domHangul: /[가-힯]/.test(after.dom),
        domHangulLines: nonblank(after.dom).filter((l) => /[가-힯]/.test(l)).length,
        domLastUserLineHangul: (() => { const nb = nonblank(after.dom).filter((l) => l !== '--' && l !== 'Sig' && !l.startsWith('On Monday')); return nb.length ? /[가-힯]/.test(nb[nb.length - 1]) : null; })(),
        domMarkers: (after.dom.match(/EN\d+/g) || []).length, outMarkers: (out.match(/EN\d+/g) || []).length,
        modelBlocks: after.model ? after.model.length : null,
        modelNonblankEq: after.model ? JSON.stringify(nonblank(after.model.join('\n'))) === JSON.stringify(nonblank(out)) : null,
        modelHangul: after.model ? /[가-힯]/.test(after.model.join('\n')) : null,
        modelStructEq: after.model ? after.model.join('\n') === out : null,
        modelBlockShape: after.model ? after.model.map((b) => b.split('\n').length).join('/') : null,
        outShape: out.split('\n').length,
      };
    }
    if (process.env.DEBUG) console.error('AFTER', await p.evaluate(() => (document.getElementById('ed') || document.querySelector('#edwrap [contenteditable]')).outerHTML), JSON.stringify(after?.model));
    const ui = await protlyUi(cdp);
    if (process.env.DEBUG) console.error('UI', ui);
    rec.ui = classifyUi(ui);
    rec.ms = Date.now() - t0;
  } catch (e) {
    rec.error = String(e.message || e).slice(0, 200);
  } finally {
    await p.close().catch(() => {});
  }
  return rec;
}

const SURFACES = [
  'ig:lexical-rich', 'ig:lexical-plain', 'wa:lexical-rich', 'wa:lexical-plain',
  'gm:none', 'gm:flat', 'gm:wrapped', 'gm:quote',
  'gen:textarea', 'gen:ce', 'gen:lexical-rich', 'gen:lexical-plain', 'gen:draft', 'gen:slate',
];

(async () => {
  const ctx = await chromium.launchPersistentContext('', {
    headless: true, channel: 'chromium',
    args: [`--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`],
  });
  for (const host of ['www.instagram.com', 'web.whatsapp.com', 'mail.google.com']) {
    await ctx.route(`https://${host}/**`, (r) => {
      const u = r.request().url();
      if (u.includes('/__probe/editors.js')) return r.fulfill({ contentType: 'application/javascript', body: bundle });
      if (r.request().resourceType() !== 'document') return r.fulfill({ status: 404, body: '' });
      return r.fulfill({ contentType: 'text/html; charset=utf-8', body: htmlFor(u) });
    });
  }
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker', { timeout: 15000 });
  await installFake(sw);
  const reps = filter.reps ?? 10;
  const surfaces = filter.surfaces ?? SURFACES;
  const ns = filter.n ?? [3, 5];
  const modes = filter.lineMode ?? ['para', 'blank', 'paste'];
  const cursors = filter.cursor ?? ['end', 'middle', 'selection'];
  const imes = filter.ime ?? [false, true];
  const delays = filter.delay ?? [300];
  const out = fs.createWriteStream(OUT, { flags: 'a' });
  let count = 0;
  for (const surface of surfaces) {
    const triggers = filter.trigger ?? (surface.startsWith('ig:') || surface.startsWith('wa:') ? ['altT', 'enter'] : ['altT']);
    for (const n of ns) for (const lineMode of modes) for (const cursor of cursors) for (const ime of imes) for (const trigger of triggers) for (const delay of delays) {
      if (ime && lineMode.startsWith('paste')) continue; // a paste has no composition
      for (let rep = 0; rep < reps; rep++) {
        await installFake(sw);
        const rec = await trial(ctx, sw, { surface, n, lineMode, cursor, ime, trigger, delay, rep });
        out.write(`${JSON.stringify(rec)}\n`);
        count++;
        if (count % 25 === 0) console.log(count, surface);
      }
    }
  }
  out.end();
  await ctx.close();
  console.log('done', count);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
