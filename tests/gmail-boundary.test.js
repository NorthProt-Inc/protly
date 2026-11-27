// A Gmail draft whose last line sits next to a signature or a quote (diagnosis 2026-11-17, P1b-1).
//
// The layouts are Chromium's own markup: lines typed with Ctrl+Home, Input.insertText and Enter (Shift+Enter where
// named) into the starting bodies of the diag/p1-chrome harness (probe/p1-chrome/harness.cjs), captured from
// Chrome for Testing 156.0.8078.4 on 2026-11-17. The starting bodies themselves were made up by the harness, not
// taken from Gmail. The "real Gmail" rows are what ties them to Gmail: the body structure printed in a real Gmail
// compose (Chrome, 2026-11-26) after typing three lines, forward and reply, with and without an Enter after the last.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { GSEL } from '../src/content/gmail/selectors.js';
import { userNodes, nodesToText, textToNodes, replaceUserNodes, hasMedia } from '../src/content/gmail/body.js';
import { translate } from '../src/content/gmail/compose.js';
import { shadowOf } from '../src/ui/card.js';

const SIG = '<span class="gmail_signature_prefix">-- </span><br><div class="gmail_signature" data-smartmail="gmail_signature">Sig</div>';
const WSIG = '<span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">Sig</div>';
const QUOTE = '<div class="gmail_quote">On Monday someone wrote: old text</div>';
const L3 = '가나다\n라마바\n사아자';
// Real Gmail (2026-11-26): the attribution sits inside the quote container, the reply's quote in a blockquote.
const FWD = '<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>From: <strong class="gmail_sendername" dir="auto">A</strong> <span dir="auto">&lt;a@example.com&gt;</span><br>Date: Mon<br>Subject: S<br>To: &lt;b@example.com&gt;<br></div><br><br>old text</div>';
const RQ = '<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Mon, A wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex">old text</blockquote></div>';

// No Enter after the last line: Chrome leaves that line in the block that holds the signature or quote.
// main read, sent and replaced every line but that one, and its write check passed.
const SHARED = [
  ['flat signature, 3 lines', `가나다<div>라마바</div><div>사아자<br><div><br></div>${SIG}</div>`, L3],
  ['wrapped signature, 3 lines', `<div dir="ltr">가나다</div><div dir="ltr">라마바</div><div dir="ltr">사아자<br><div><br></div>${WSIG}</div>`, L3],
  ['expanded quote, 3 lines', `가나다<div>라마바</div><div>사아자<br>${QUOTE}</div>`, L3],
  ['flat signature, 2 lines', `가나다<div>라마바<br><div><br></div>${SIG}</div>`, '가나다\n라마바'],
  ['wrapped signature, 2 lines', `<div dir="ltr">가나다</div><div dir="ltr">라마바<br><div><br></div>${WSIG}</div>`, '가나다\n라마바'],
  ['expanded quote, 2 lines', `가나다<div>라마바<br>${QUOTE}</div>`, '가나다\n라마바'],
  ['flat signature, blank lines between', `가나다<div><br></div><div>라마바</div><div><br></div><div>사아자<br><div><br></div>${SIG}</div>`, '가나다\n\n라마바\n\n사아자'],
  // Printed in real Gmail: #text DIV(#text) DIV(#text BR BR DIV.gmail_quote.gmail_quote_container(...)).
  ['real Gmail forward, 3 lines', `가나다<div>라마바</div><div>사아자<br><br>${FWD}</div>`, L3],
  ['expanded quote, blank lines between', `가나다<div><br></div><div>라마바</div><div><br></div><div>사아자<br>${QUOTE}</div>`, '가나다\n\n라마바\n\n사아자'],
];

// Layouts main already read whole.
const WORKED = [
  // Printed in real Gmail: #text DIV(#text) DIV(#text) DIV(BR BR DIV.gmail_quote.gmail_quote_container(...)).
  ['real Gmail forward, Enter after the last line', `가나다<div>라마바</div><div>사아자</div><div><br><br>${FWD}</div>`, L3],
  // Printed in real Gmail after "Show trimmed content": DIV(#text DIV(#text) DIV(#text)) BR DIV.gmail_quote...(DIV.gmail_attr
  // BLOCKQUOTE.gmail_quote). With the quote collapsed it is outside the body and the draft is the "no signature" row.
  ['real Gmail reply, quote expanded', `<div>가나다<div>라마바</div><div>사아자</div></div><br>${RQ}`, L3],
  ['no signature', '가나다<div>라마바</div><div>사아자</div>', L3],
  ['flat signature, Enter after the last line', `가나다<div>라마바</div><div>사아자</div><div><br><div><br></div>${SIG}</div>`, L3],
  ['wrapped signature, Enter after the last line', `<div dir="ltr">가나다</div><div dir="ltr">라마바</div><div dir="ltr">사아자</div><div dir="ltr"><br><div><br></div>${WSIG}</div>`, L3],
  ['expanded quote, Enter after the last line', `가나다<div>라마바</div><div>사아자</div><div><br>${QUOTE}</div>`, L3],
  ['flat signature, single line', `가나다<br><div><br></div>${SIG}`, '가나다'],
  ['wrapped signature, single line', `<div dir="ltr">가나다<br><div><br></div>${WSIG}</div>`, '가나다'],
  ['expanded quote, single line', `가나다<br>${QUOTE}`, '가나다'],
  ['flat signature, Shift+Enter lines', `가나다<br>라마바<br>사아자<br><div><br></div>${SIG}`, L3],
  // Not captured: the shape of the older wrapper test in gmail.test.js.
  ['reopened draft wrapped in one div', `<div dir="ltr">가나다<div>라마바</div><div>사아자</div><br>${WSIG}</div>`, L3],
];

const bodyOf = (html) => {
  const doc = new JSDOM(`<body><div id="b">${html}</div></body>`).window.document;
  return { doc, body: doc.getElementById('b') };
};
const whole = (body) => nodesToText([body]);
// The translation keeps the draft's lines: nonblank line k becomes ENk.
const english = (typed) => typed.split('\n').map((l, i) => (l ? `EN${i + 1}` : '')).join('\n');
// Every quote or signature block with where it sits and what it holds.
const boundaries = (body) => [...body.querySelectorAll(GSEL.boundary)].map((n) => ({ n, parent: n.parentNode, next: n.nextSibling, html: n.outerHTML }));

function checkLayout(html, typed) {
  const { doc, body } = bodyOf(html);
  const before = whole(body);
  const beforeHtml = body.innerHTML;
  const kept = boundaries(body);
  assert.ok(before === typed || before.startsWith(`${typed}\n`), 'the draft comes first in the body');

  // Read: every typed line.
  assert.equal(nodesToText(userNodes(body)), typed);

  // Replace: the translation takes the place of every typed line; the rest of the body, blank lines before the
  // signature or quote included, reads exactly as before.
  const en = english(typed);
  const removed = replaceUserNodes(body, textToNodes(doc, en));
  assert.equal(whole(body), en + before.slice(typed.length));
  assert.equal(nodesToText(userNodes(body)), en);
  // The signature or quote is the same node, unchanged, in the same place.
  assert.deepEqual(boundaries(body), kept);

  // Undo: the draft is back as it was.
  replaceUserNodes(body, removed);
  assert.equal(whole(body), before);
  assert.equal(body.innerHTML, beforeHtml);
  assert.deepEqual(boundaries(body), kept);
}

for (const [name, html, typed] of SHARED) {
  test(`last line in the signature or quote block (${name}): read, replace and undo cover every line`, () => checkLayout(html, typed));
}

for (const [name, html, typed] of WORKED) {
  test(`layout that worked (${name}): read, replace and undo cover every line, blank lines kept`, () => checkLayout(html, typed));
}

test('Undo after Gmail replaced the signature block puts every line back in order', () => {
  // A reopened draft with an empty first line; the last line sits in the signature's block.
  const { doc, body } = bodyOf(`<div><br></div><div dir="ltr">가나다<div>라마바</div><div>사아자<br><div><br></div>${SIG}</div></div>`);
  const before = whole(body);
  assert.equal(before, '\n가나다\n라마바\n사아자\n\n-- \nSig');
  const removed = replaceUserNodes(body, textToNodes(doc, '\nEN1\nEN2\nEN3'));
  // Gmail renders the signature's block again: the block the last line came from is gone, its wrapper is not.
  const block = body.querySelector('.gmail_signature').parentNode;
  block.replaceWith(block.cloneNode(true));
  replaceUserNodes(body, removed);
  assert.equal(whole(body), before);
});

test('Undo after Gmail replaced the block of the second of two lines keeps them two lines', () => {
  const { doc, body } = bodyOf(`가나다<div>라마바<br><div><br></div>${SIG}</div>`);
  const before = whole(body);
  const removed = replaceUserNodes(body, textToNodes(doc, 'EN1\nEN2'));
  const block = body.querySelector('.gmail_signature').parentNode; // held 라마바 and its <br>
  block.replaceWith(block.cloneNode(true));
  replaceUserNodes(body, removed);
  assert.equal(whole(body), before);
});

test('a translation replaced again (Deep, language chip) keeps the signature block and its blank line', () => {
  const [, html, typed] = SHARED[0];
  const { doc, body } = bodyOf(html);
  const before = whole(body);
  const kept = boundaries(body);
  const original = replaceUserNodes(body, textToNodes(doc, english(typed)));
  replaceUserNodes(body, textToNodes(doc, 'Deep 1\nDeep 2'));
  assert.equal(whole(body), `Deep 1\nDeep 2${before.slice(typed.length)}`);
  assert.deepEqual(boundaries(body), kept);
  replaceUserNodes(body, original);
  assert.equal(whole(body), before);
});

// Through compose.js: the request carries every line, the body shows the whole translation and Undo restores it.
const html = readFileSync(new URL('./fixtures/gmail.html', import.meta.url), 'utf8');
const flush = () => new Promise((r) => setTimeout(r, 0));

function setup(layout) {
  globalThis.document = new JSDOM(`<body>${html}</body>`).window.document;
  const calls = [];
  const pending = [];
  globalThis.chrome = {
    runtime: {
      sendMessage: (msg) => {
        if (msg.type === 'badge') return Promise.resolve({ ok: true, data: true });
        calls.push(msg);
        return new Promise((res) => pending.push(res));
      },
    },
  };
  const body = document.querySelector(GSEL.body);
  body.innerHTML = layout;
  const reply = async (r) => { pending.shift()(r); await flush(); };
  const note = () => { const h = document.querySelector('.pl-card'); return h ? shadowOf(h).querySelector('.pl-root') : null; };
  const buttonIn = (label) => [...(note()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  return { body, calls, reply, note, buttonIn };
}
const ok = (translation) => ({ ok: true, data: { lang: 'en', translation, back_translation: '역번역', model: 'claude-sonnet-5-5' } });

for (const [name, layout, typed] of SHARED.slice(0, 3)) {
  test(`Translate in a compose (${name}): every line is sent and replaced, Undo brings the draft back`, async () => {
    const { body, calls, reply, note, buttonIn } = setup(layout);
    const before = whole(body);
    const beforeHtml = body.innerHTML;
    const sig = body.querySelector(GSEL.boundary);
    translate(body);
    assert.equal(calls[0].korean, typed);
    await reply(ok(english(typed)));
    assert.match(note().textContent, /역번역/); // the preview, not an error
    assert.equal(whole(body), english(typed) + before.slice(typed.length));
    assert.equal(body.querySelector(GSEL.boundary), sig);
    buttonIn('Undo').click();
    assert.equal(whole(body), before);
    assert.equal(body.innerHTML, beforeHtml);
  });
}

// Cross-model review 2026-11-26 (Gemini): quote and signature markers the selector missed, an image taken for a blank
// line, and line ends after inline formatting.
const readOf = (html) => nodesToText(userNodes(bodyOf(html).body));
test('a legacy .gmail_extra wrapper is a boundary: its attribution is not read as the draft', () => {
  assert.equal(readOf('가나다<div>라마바</div><div class="gmail_extra"><br><div class="gmail_attr">On Mon, A wrote:</div><blockquote class="gmail_quote">Old</blockquote></div>'), '가나다\n라마바');
});
test('a signature marked only by data-smartmail is a boundary', () => {
  assert.equal(readOf('가나다<div>라마바</div><div>사아자<br><div><br></div><div data-smartmail="gmail_signature"><div dir="ltr">Best</div></div></div>'), L3);
});
test('a cited blockquote is a boundary, an indent blockquote is the draft', () => {
  assert.equal(readOf('가나다<div>라마바</div><blockquote type="cite">Old</blockquote>'), '가나다\n라마바');
  assert.equal(readOf('가나다<blockquote style="margin:0 0 0 40px;border:none;padding:0px">라마바</blockquote><div>사아자</div>'), L3);
});
test('an image at the end of the last line is media, not a blank line', () => {
  assert.equal(hasMedia(userNodes(bodyOf(`가나다<div>라마바<img src="e.png"><br>${SIG}</div>`).body)), true);
});
test('a line ending in bold and a space keeps its line end inside the draft', () => {
  const { doc, body } = bodyOf(`가나다<div><b>라마바</b>\u00a0<br><div><br></div>${SIG}</div>`);
  replaceUserNodes(body, textToNodes(doc, 'EN1\nEN2'));
  assert.equal(whole(body), 'EN1\nEN2\n\n-- \nSig');
});
test('an inline wrapper that ends its own line leaves the blank line after it alone', () => {
  const { doc, body } = bodyOf(`가나다<div><span>라마바<br></span><br>${SIG}</div>`);
  replaceUserNodes(body, textToNodes(doc, 'EN1\nEN2'));
  assert.equal(whole(body), 'EN1\nEN2\n\n-- \nSig');
});
