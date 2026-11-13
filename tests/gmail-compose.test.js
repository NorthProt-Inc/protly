import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { GSEL } from '../src/content/gmail/selectors.js';
import { userNodes, nodesToText } from '../src/content/gmail/body.js';
import { mountCompose, translate, undo, keep, undoKey } from '../src/content/gmail/compose.js';
import { flags } from '../src/lib/flags.js';
import { shadowOf } from '../src/ui/card.js';

const html = readFileSync(new URL('./fixtures/gmail.html', import.meta.url), 'utf8');
const KOREAN = '한글 첫줄\n둘째 줄\n\n셋째 문단';
const flush = () => new Promise((r) => setTimeout(r, 0));
const ok = (translation, model = 'claude-sonnet-5-5') =>
  ({ ok: true, data: { lang: 'en', translation, back_translation: '역번역', model } });

// compose.js reads the page through the globals document and chrome; each test gets a fresh page.
function setup() {
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
  const [inline, dialog] = document.querySelectorAll(GSEL.body);
  const reply = async (r) => { pending.shift()(r); await flush(); };
  // The card renders in a closed shadow root (shadowOf is protly's own handle); its .pl-root holds the text, buttons and picker.
  const note = () => { const h = document.querySelector('.pl-card'); return h ? shadowOf(h).querySelector('.pl-root') : null; };
  const buttonIn = (label) => [...(note()?.querySelectorAll('button') || [])].find((b) => b.textContent === label);
  return { inline, dialog, calls, reply, note, buttonIn };
}
const userText = (body) => nodesToText(userNodes(body));
const ENGLISH = 'Hi Prof. Allen,\nI has a question.\n\nThanks,\nCyan';
const polished = (translation, model = 'claude-sonnet-5-5') =>
  ({ ok: true, data: { translation, back_translation: '바뀐 점', model } }); // polish returns no lang
const draft = (body, text) => body.replaceChildren(document.createTextNode(text));

test('the button mounts next to each compose\'s own Send, once', () => {
  const { inline, dialog } = setup();
  mountCompose(inline);
  mountCompose(inline);
  mountCompose(dialog);
  assert.equal(inline.closest('.reply').querySelectorAll('.pl-g-btn').length, 1);
  assert.equal(dialog.closest('[role="dialog"]').querySelectorAll('.pl-g-btn').length, 1);
});

test('a body whose toolbar renders later gets its button on a later scan', () => {
  setup();
  const box = document.createElement('div');
  const body = document.createElement('div');
  body.setAttribute('role', 'textbox');
  body.setAttribute('aria-label', 'Message Body');
  body.setAttribute('contenteditable', 'true');
  box.appendChild(body);
  document.body.appendChild(box);
  mountCompose(body);
  assert.equal(box.querySelector('.pl-g-btn'), null);
  const table = document.createElement('table');
  table.setAttribute('role', 'group');
  const td = table.insertRow().insertCell();
  const send = document.createElement('div');
  send.setAttribute('role', 'button');
  send.setAttribute('data-tooltip', 'Send (Ctrl-Enter)');
  td.appendChild(send);
  box.appendChild(table);
  mountCompose(body);
  assert.ok(box.querySelector('.pl-g-btn'));
});

test('translate replaces the user part, Undo brings the Korean back, signature untouched', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  const sig = inline.querySelector('.gmail_signature');
  translate(inline);
  assert.match(note().textContent, /Translating/);
  assert.equal(calls[0].korean, KOREAN);
  assert.equal(calls[0].context.length, 2); // inline reply: thread context
  await reply(ok('Line one\nLine two'));
  assert.equal(userText(inline), 'Line one\nLine two');
  assert.match(note().textContent, /역번역/);
  buttonIn('Undo').click();
  assert.equal(userText(inline), KOREAN);
  assert.equal(inline.querySelector('.gmail_signature'), sig);
  assert.equal(note(), null);
});

test('a new compose window sends no thread context', () => {
  const { dialog, calls } = setup();
  dialog.replaceChildren(document.createTextNode('새 메일'));
  translate(dialog);
  assert.deepEqual(calls[0].context, []);
});

test('typing while translating drops the result and keeps the typing', async () => {
  const { inline, reply, note } = setup();
  translate(inline);
  inline.firstChild.textContent += ' 추가';
  await reply(ok('Translated'));
  assert.equal(userText(inline), KOREAN.replace('한글 첫줄', '한글 첫줄 추가'));
  assert.match(note().textContent, /draft changed/);
});

test('Cancel ends translating and the late result is ignored', async () => {
  const { inline, reply, note, buttonIn } = setup();
  translate(inline);
  buttonIn('Cancel').click();
  assert.equal(note(), null);
  await reply(ok('Late'));
  assert.equal(userText(inline), KOREAN);
  assert.equal(note(), null);
});

test('a failure keeps the Korean and names the problem', async () => {
  const { inline, reply, note } = setup();
  translate(inline);
  await reply({ ok: false, error: { kind: 'host', message: 'port closed' } });
  assert.equal(userText(inline), KOREAN);
  assert.match(note().textContent, /Native host not reachable/);
});

test('a failed Opus retry keeps the preview controls', async () => {
  const { inline, reply, note, buttonIn } = setup();
  translate(inline);
  await reply(ok('First'));
  buttonIn('Deep').click();
  await reply({ ok: false, error: { kind: 'timeout', message: 'slow' } });
  assert.equal(userText(inline), 'First');
  assert.match(note().textContent, /too long/);
  assert.ok(buttonIn('Deep') && buttonIn('Undo') && note().querySelector('select'));
  buttonIn('Undo').click();
  assert.equal(userText(inline), KOREAN);
});

test('Opus after editing the translation asks before replacing the edit', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  translate(inline);
  await reply(ok('First'));
  inline.firstChild.textContent = 'First, edited';
  buttonIn('Deep').click();
  assert.equal(calls.length, 1); // nothing sent yet
  assert.match(note().textContent, /You edited the translation/);
  buttonIn('Replace anyway').click();
  assert.equal(calls.length, 2);
  assert.equal(calls[1].profile, 'hard');
  assert.equal(calls[1].korean, KOREAN);
  await reply(ok('Second', 'claude-opus-5-5'));
  assert.equal(userText(inline), 'Second');
  assert.equal(note().querySelector('.model').textContent, 'Opus deep');
  undo(inline);
  assert.equal(userText(inline), KOREAN); // Undo still goes back to the original Korean
});

test('the button title mentions polish, the label stays Translate', () => {
  const { inline } = setup();
  mountCompose(inline);
  const btn = inline.closest('.reply').querySelector('.pl-g-btn');
  assert.equal(btn.textContent, 'Translate');
  assert.match(btn.title, /polish an English one/);
  assert.match(btn.title, /ru:/);
});

test('a page script clicking the Translate button sends nothing; the user\'s own click does', async () => {
  const { inline, calls } = setup();
  mountCompose(inline);
  draft(inline, '안녕하세요');
  const btn = inline.closest('.reply').querySelector('.pl-g-btn');
  btn.click(); // jsdom events are untrusted, like a page's synthetic click
  btn.dispatchEvent(new document.defaultView.MouseEvent('click', { bubbles: true }));
  assert.equal(calls.length, 0);
  const { _trustSyntheticEvents } = await import('../src/ui/trust.js');
  _trustSyntheticEvents(true);
  try {
    btn.click();
    assert.equal(calls.length, 1);
    assert.equal(calls[0].type, 'email');
  } finally {
    _trustSyntheticEvents(false);
  }
});

test('an English draft gets one polish call, Undo restores the English', async () => {
  const { dialog, calls, reply, note, buttonIn } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  assert.match(note().textContent, /^Polishing/);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], { type: 'polish', text: ENGLISH, profile: 'email' });
  await reply(polished('Hi Prof. Allen,\nI have a question.\n\nThanks,\nCyan'));
  assert.equal(userText(dialog), 'Hi Prof. Allen,\nI have a question.\n\nThanks,\nCyan');
  assert.match(note().textContent, /바뀐 점/);
  buttonIn('Undo').click();
  assert.equal(userText(dialog), ENGLISH);
  assert.equal(note(), null);
});

test('the popup polish toggle does not gate the button: polish off still polishes', async () => {
  flags.polish = false;
  const { dialog, calls } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], { type: 'polish', text: ENGLISH, profile: 'email' });
});

test('digits or emoji only is nothing to do, no call', () => {
  const { dialog, calls, note } = setup();
  draft(dialog, '123 🙂');
  translate(dialog);
  assert.equal(calls.length, 0);
  assert.match(note().textContent, /Nothing to translate or polish/);
});

test('an English edit in a polish preview is an error, no call, Undo keeps the original', async () => {
  const { dialog, calls, reply, note, buttonIn } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  await reply(polished('Polished'));
  draft(dialog, 'Polished, edited');
  translate(dialog);
  assert.equal(calls.length, 1);
  assert.match(note().textContent, /To polish this English, press Undo first/);
  assert.ok(buttonIn('Deep') && buttonIn('Undo'));
  buttonIn('Undo').click();
  assert.equal(userText(dialog), ENGLISH);
});

test('an English edit in a translate preview is an error, Undo keeps the Korean', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  translate(inline);
  await reply(ok('First'));
  inline.firstChild.textContent = 'First, edited';
  translate(inline);
  assert.equal(calls.length, 1);
  assert.match(note().textContent, /press Undo first/);
  buttonIn('Undo').click();
  assert.equal(userText(inline), KOREAN);
});

test('a ru: prefix sends lang ru without the prefix, Undo brings back the prefixed draft', async () => {
  const { dialog, calls, reply, buttonIn } = setup();
  draft(dialog, 'ru: 안녕하세요');
  translate(dialog);
  assert.equal(calls[0].type, 'email');
  assert.equal(calls[0].lang, 'ru');
  assert.equal(calls[0].korean, '안녕하세요');
  await reply({ ok: true, data: { lang: 'ru', translation: 'Здравствуйте', back_translation: '안녕하세요', model: 'claude-sonnet-5-5' } });
  assert.equal(userText(dialog), 'Здравствуйте');
  buttonIn('Undo').click();
  assert.equal(userText(dialog), 'ru: 안녕하세요');
});

test('an English draft with a ru: prefix is translated into Russian, not polished; Undo brings back the draft', async () => {
  const { dialog, calls, reply, buttonIn } = setup();
  draft(dialog, 'ru: see you tomorrow');
  translate(dialog);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].type, 'email');
  assert.equal(calls[0].lang, 'ru');
  assert.equal(calls[0].korean, 'see you tomorrow');
  await reply({ ok: true, data: { lang: 'ru', translation: 'Увидимся завтра', back_translation: '내일 봐', model: 'claude-sonnet-5-5' } });
  assert.equal(userText(dialog), 'Увидимся завтра');
  buttonIn('Undo').click();
  assert.equal(userText(dialog), 'ru: see you tomorrow');
});

test('uppercase RU: and en: on English still polish', () => {
  for (const text of ['RU: see you', 'en: see you']) {
    const { dialog, calls } = setup();
    draft(dialog, text);
    translate(dialog);
    assert.equal(calls[0].type, 'polish', text);
  }
});

test('a prefixed English draft typed over a translate preview is translated', async () => {
  const { inline, calls, reply } = setup();
  translate(inline);
  await reply(ok('First'));
  draft(inline, 'ja: thanks');
  translate(inline);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].type, 'email');
  assert.equal(calls[1].lang, 'ja');
  assert.equal(calls[1].korean, 'thanks');
});

test('a mid-draft span sends the tagged text with lang auto', async () => {
  const { dialog, calls } = setup();
  draft(dialog, '안녕 fr:고마워; 잘가');
  translate(dialog);
  assert.equal(calls[0].type, 'email');
  assert.equal(calls[0].lang, 'auto');
  assert.equal(calls[0].korean, '안녕 <fr>고마워</fr> 잘가');
});

test('a polish preview has Opus and Undo but no language picker', async () => {
  const { dialog, reply, note, buttonIn } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  await reply(polished('Polished'));
  assert.equal(note().querySelector('select'), null);
  assert.ok(buttonIn('Deep') && buttonIn('Undo'));
});

test('Opus in a polish preview re-polishes with the hard profile', async () => {
  const { dialog, calls, reply, note, buttonIn } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  await reply(polished('Polished'));
  buttonIn('Deep').click();
  assert.match(note().textContent, /Polishing deeply/);
  assert.deepEqual(calls[1], { type: 'polish', text: ENGLISH, profile: 'hard' });
  await reply(polished('Polished harder', 'claude-opus-5-5'));
  assert.equal(userText(dialog), 'Polished harder');
  assert.equal(note().querySelector('.model').textContent, 'Opus deep');
  assert.equal(note().querySelector('select'), null);
  undo(dialog);
  assert.equal(userText(dialog), ENGLISH);
});

test('Korean typed over a polish preview starts a translation', async () => {
  const { dialog, calls, reply, note } = setup();
  draft(dialog, ENGLISH);
  translate(dialog);
  await reply(polished('Polished'));
  draft(dialog, '새 초안');
  translate(dialog);
  assert.equal(calls[1].type, 'email');
  assert.equal(calls[1].korean, '새 초안');
  await reply(ok('New draft'));
  assert.ok(note().querySelector('select')); // back to a translate preview
});

test('Esc keeps a preview, Alt+Z undoes it (also after Esc), and either cancels a translation in flight', async () => {
  const { inline, reply, note, buttonIn } = setup();
  assert.equal(keep(inline), false); // idle: Gmail keeps the key
  assert.equal(undoKey(inline), false);
  translate(inline);
  await reply(ok('First'));
  inline.firstChild.textContent = 'First, edited';
  assert.equal(keep(inline), true);
  assert.equal(userText(inline), 'First, edited');
  assert.equal(note(), null);
  assert.equal(keep(inline), false); // kept: the next Esc is Gmail's
  assert.equal(undoKey(inline), true); // unchanged since Esc: restored at once
  assert.equal(userText(inline), KOREAN);
  assert.equal(undoKey(inline), false); // nothing left to undo

  translate(inline);
  await reply(ok('Second'));
  inline.firstChild.textContent = 'Second, edited';
  assert.equal(undoKey(inline), true); // an edited translation asks first: Ctrl+Z cannot bring an edit back
  assert.equal(userText(inline), 'Second, edited');
  assert.match(note().textContent, /drops your changes/);
  buttonIn('Keep my text').click();
  assert.match(note().textContent, /역번역/); // back to the preview
  assert.equal(undoKey(inline), true);
  buttonIn('Undo anyway').click();
  assert.equal(userText(inline), KOREAN);
  assert.equal(note(), null);

  for (const act of [keep, undoKey]) {
    translate(inline);
    assert.equal(act(inline), true);
    await reply(ok('Late'));
    assert.equal(userText(inline), KOREAN);
    assert.equal(note(), null);
  }
});

test('the preview card shows the model and the Esc hint', async () => {
  const { inline, reply, note } = setup();
  translate(inline);
  await reply(ok('First', 'claude-opus-5-5'));
  assert.equal(note().querySelector('.model').textContent, 'Opus');
  assert.equal(note().querySelector('.hints').textContent, 'Esc keep · Alt+Z undo');
});

test('Opus after editing the translation keeps the edit and asks instead', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  translate(inline);
  await reply(ok('First'));
  inline.firstChild.textContent = 'First, edited';
  buttonIn('Deep').click();
  assert.equal(userText(inline), 'First, edited');
  assert.equal(calls.length, 1);
  assert.match(note().textContent, /You edited the translation/);
  buttonIn('Keep my edit').click();
  assert.equal(userText(inline), 'First, edited');
  assert.match(note().textContent, /역번역/);
  buttonIn('Undo').click();
  assert.equal(userText(inline), KOREAN); // an explicit Undo still goes back
});

test('changing the language puts focus back in the compose body', async () => {
  const { inline, calls, reply, note } = setup();
  translate(inline);
  await reply(ok('First'));
  const sel = note().querySelector('select');
  sel.focus();
  sel.value = 'ja';
  sel.dispatchEvent(new document.defaultView.Event('change'));
  assert.equal(calls[1].lang, 'ja');
  assert.equal(document.activeElement, inline);
});

test('a reloaded extension shows the stale error, not Chrome\'s message', async () => {
  for (const message of ['Could not establish connection. Receiving end does not exist.', 'Extension context invalidated.']) {
    const { inline, note } = setup();
    chrome.runtime.sendMessage = (msg) => (msg.type === 'badge'
      ? Promise.resolve({ ok: true, data: true })
      : Promise.reject(new Error(message)));
    translate(inline);
    await flush();
    assert.match(note().textContent, /protly was reloaded or updated/);
    assert.doesNotMatch(note().textContent, /Receiving end|context invalidated/);
  }
});

// Bracket notes (plan docs/plans/2026-11-08-notes-and-iphone-port.md, Part A).
const NOTES_ONLY = 'Add the message too. [Brackets] are notes for protly.';
const NOTE_ON_TRANSLATION = 'Notes work on a new draft. Undo first, then add the note.';

test('notes: the email request gets the text and the notes; Deep and the picker keep them; Undo restores the draft', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  draft(inline, '[formal] ru: 내일 보자 [짧게]');
  translate(inline);
  assert.deepEqual([calls[0].type, calls[0].korean, calls[0].lang, calls[0].notes], ['email', '내일 보자', 'ru', ['formal', '짧게']]);
  await reply(ok('До завтра'));
  buttonIn('Deep').click();
  assert.deepEqual([calls[1].profile, calls[1].korean, calls[1].notes], ['hard', '내일 보자', ['formal', '짧게']]);
  await reply(ok('До завтра.'));
  const sel = note().querySelector('select');
  sel.value = 'ja';
  sel.dispatchEvent(new document.defaultView.Event('change'));
  assert.deepEqual([calls[2].lang, calls[2].korean, calls[2].notes], ['ja', '내일 보자', ['formal', '짧게']]);
  await reply(ok('See you'));
  buttonIn('Undo').click();
  assert.equal(userText(inline), '[formal] ru: 내일 보자 [짧게]');
  assert.equal(note(), null);
  // Without notes the request carries none.
  draft(inline, '내일 보자');
  translate(inline);
  assert.equal('notes' in calls[3], false);
});

test('notes: an English draft with a note is polished with its notes', async () => {
  const { inline, calls, reply, buttonIn } = setup();
  draft(inline, 'see you [formal]');
  translate(inline);
  assert.deepEqual([calls[0].type, calls[0].text, calls[0].notes], ['polish', 'see you', ['formal']]);
  await reply(polished('See you.'));
  buttonIn('Deep').click();
  assert.deepEqual([calls[1].type, calls[1].text, calls[1].notes], ['polish', 'see you', ['formal']]);
});

test('notes: a draft of notes only runs nothing', () => {
  const { inline, calls, note } = setup();
  draft(inline, '[formal]');
  translate(inline);
  assert.equal(calls.length, 0);
  assert.equal(note().textContent.includes(NOTES_ONLY), true);
});

test('notes: a note typed into the preview or the kept translation is held', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  draft(inline, '내일 보자');
  translate(inline);
  await reply(ok('See you tomorrow'));
  draft(inline, 'See you tomorrow [shorter]');
  translate(inline);
  assert.equal(calls.length, 1);
  assert.equal(note().textContent.includes(NOTE_ON_TRANSLATION), true);
  assert.ok(buttonIn('Undo'), 'the preview controls stay');
  draft(inline, 'See you tomorrow');
  assert.equal(keep(inline), true);
  draft(inline, 'See you tomorrow [shorter]');
  translate(inline);
  assert.equal(calls.length, 1);
  assert.equal(note().textContent.includes(NOTE_ON_TRANSLATION), true);
  undo(inline);
  assert.equal(userText(inline), '내일 보자');
});

test('notes: a note on a draft with no letters still polishes; a translation that has brackets is not a new note', async () => {
  const { inline, calls, reply, note } = setup();
  draft(inline, '3 [as words]');
  translate(inline);
  assert.deepEqual([calls[0].type, calls[0].text, calls[0].notes], ['polish', '3', ['as words']]);
  await reply(polished('Three.'));
  undo(inline);
  draft(inline, '내일 보자');
  translate(inline);
  await reply(ok('See you [tomorrow]'));
  translate(inline); // the body still holds the translation: nothing new
  assert.equal(calls.length, 2);
  assert.match(note().textContent, /역번역/);
});

test('notes: Deep and the language chip hold a note typed into the preview instead of dropping it', async () => {
  const { inline, calls, reply, note, buttonIn } = setup();
  draft(inline, '내일 보자');
  translate(inline);
  await reply(ok('See you tomorrow'));
  draft(inline, 'See you tomorrow [shorter]');
  buttonIn('Deep').click();
  assert.equal(calls.length, 1);
  assert.equal(note().textContent.includes(NOTE_ON_TRANSLATION), true);
  assert.equal(userText(inline), 'See you tomorrow [shorter]');
});

test('notes: a new Korean draft with a note typed over the preview is translated with its notes', async () => {
  const { inline, calls, reply } = setup();
  draft(inline, '내일 보자');
  translate(inline);
  await reply(ok('See you tomorrow'));
  draft(inline, '새 초안 [formal]');
  translate(inline);
  assert.deepEqual([calls[1].type, calls[1].korean, calls[1].notes], ['email', '새 초안', ['formal']]);
});
