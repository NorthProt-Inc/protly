// Esc keeps a translation on Instagram: the user edits it and sends, and the send is still recorded with its Korean
// source, by Enter or by Instagram's Send button. Keys wait while a written translation is being checked.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mountInstagram } from './instagram-mount.js';
import { _trustSyntheticEvents } from '../src/ui/trust.js';
import { shadowOf } from '../src/ui/card.js';

const until = async (f, ms = 2000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 2));
  }
};

test('Instagram: Esc keeps the translation, an edit is sent with the Korean source, Alt+Z still undoes', async () => {
  const { win, asked, composer } = await mountInstagram({
    outgoing: async () => ({ ok: true, data: { translation: 'See you, 지민', back_translation: '또 봐, 지민', lang: 'en', model: 'claude-sonnet-5-5' } }),
  });
  const doc = win.document;
  // jsdom has no execCommand: insertText replaces a select-all, as Lexical does.
  doc.execCommand = (cmd, ui, text) => {
    composer.textContent = doc.getSelection().toString() === composer.textContent ? text : composer.textContent + text;
    return true;
  };
  const key = (init) => {
    const e = new win.KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init });
    composer.dispatchEvent(e);
    return e;
  };
  const enter = () => key({ key: 'Enter', code: 'Enter' });
  const esc = () => key({ key: 'Escape', code: 'Escape' });
  const card = () => doc.querySelector('.pl-card');
  const hints = () => { const h = card(); return h ? shadowOf(h).querySelector('.hints')?.textContent : undefined; };
  const sent = () => asked.filter((m) => m.type === 'sent').map(({ text, korean }) => ({ text, korean }));
  const translate = async () => {
    composer.textContent = '지민아 또 봐';
    composer.focus();
    assert.equal(enter().defaultPrevented, true);
    await until(() => composer.textContent === 'See you, 지민');
    // Written, not yet checked: a key now would act on an unchecked translation.
    assert.equal(esc().defaultPrevented, true);
    assert.equal(enter().defaultPrevented, true);
    await until(() => hints());
    assert.equal(hints(), 'Enter send · Esc keep · Alt+Z undo · Alt+Enter Opus');
  };

  _trustSyntheticEvents(true);
  try {
    // 1. Esc keeps the translation and closes the card. An edit without new Hangul goes out on Enter, recorded with
    // the Korean draft.
    await translate();
    assert.equal(esc().defaultPrevented, true);
    assert.equal(card(), null);
    assert.equal(composer.textContent, 'See you, 지민');
    assert.equal(esc().defaultPrevented, false); // the page's Esc again
    composer.textContent = 'See you soon, 지민';
    assert.equal(enter().defaultPrevented, false); // Instagram sends it
    assert.deepEqual(sent(), [{ text: 'See you soon, 지민', korean: '지민아 또 봐' }]);

    // 2. Kept, then Instagram's Send button empties the box: recorded too.
    await translate();
    esc();
    composer.textContent = '';
    await until(() => sent().length === 2);
    assert.deepEqual(sent()[1], { text: 'See you, 지민', korean: '지민아 또 봐' });

    // 3. Alt+Z after Esc puts the Korean back.
    await translate();
    esc();
    assert.equal(key({ key: 'z', code: 'KeyZ', altKey: true }).defaultPrevented, true);
    await until(() => composer.textContent === '지민아 또 봐');
    assert.equal(key({ key: 'z', code: 'KeyZ', altKey: true }).defaultPrevented, false);
  } finally {
    _trustSyntheticEvents(false);
  }
});
