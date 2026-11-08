// The Instagram outgoing handler as mounted by the content script (instagram-mount.js): outgoing.js's keydown
// listener is the one a page script's synthetic Enter reaches.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mountInstagram } from './instagram-mount.js';

test('Instagram: a synthetic Enter on Hangul in the composer is held and asks for nothing', async () => {
  const { win, asked, composer } = await mountInstagram();
  const billed = () => asked.map((m) => m.type).filter((t) => t === 'outgoing' || t === 'polish');
  const enter = () => new win.KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
  let pageSaw = 0;
  composer.addEventListener('keydown', () => { pageSaw++; }); // Instagram's own send handler sits here
  composer.textContent = '안녕';
  composer.focus();
  asked.length = 0;

  const e = enter();
  assert.equal(e.isTrusted, false);
  composer.dispatchEvent(e);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(e.defaultPrevented, true); // held, not passed through to Instagram
  assert.equal(pageSaw, 0);
  assert.deepEqual(billed(), []); // nothing billed

  // Control: the same Enter from the user reaches the handler and starts a translation, so the hold above is the
  // guard's doing and not an unmounted handler.
  const { _trustSyntheticEvents } = await import('../src/ui/trust.js');
  _trustSyntheticEvents(true);
  try {
    const own = enter();
    composer.dispatchEvent(own);
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(own.defaultPrevented, true);
    assert.deepEqual(billed(), ['outgoing']);
  } finally {
    _trustSyntheticEvents(false);
  }
});
