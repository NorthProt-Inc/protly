import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decideBox, decideSelection } from '../src/generic/decide.js';

test('decideBox: a prefix translates the rest, whatever its script', () => {
  assert.deepEqual(decideBox('ru: 안녕'), { kind: 'translate', lang: 'ru', text: '안녕' });
  assert.deepEqual(decideBox('ja: see you tomorrow'), { kind: 'translate', lang: 'ja', text: 'see you tomorrow' });
});

test('decideBox: a prefix with nothing after it does nothing', () => {
  assert.deepEqual(decideBox('ru:   '), { kind: 'none' });
});

test('decideBox: spans reach the request, with or without a leading prefix', () => {
  assert.deepEqual(decideBox('안녕 fr:고마워; 잘가'), { kind: 'translate', lang: 'en', text: '안녕 <fr>고마워</fr> 잘가' });
  assert.deepEqual(decideBox('ru: 안녕 fr:고마워;'), { kind: 'translate', lang: 'ru', text: '안녕 <fr>고마워</fr>' });
});

test('decideBox: Hangul goes to English', () => {
  assert.deepEqual(decideBox('내일 봐 ㅋㅋ'), { kind: 'translate', lang: 'en', text: '내일 봐 ㅋㅋ' });
});

test('decideBox: other letters are polished', () => {
  assert.deepEqual(decideBox('i has a question'), { kind: 'polish', text: 'i has a question' });
  assert.deepEqual(decideBox('привет как дела'), { kind: 'polish', text: 'привет как дела' });
});

test('decideBox: no letters, nothing to do', () => {
  for (const s of ['', '   ', '123 🙂', '!!!']) assert.deepEqual(decideBox(s), { kind: 'none' });
});

test('decideSelection', () => {
  assert.equal(decideSelection('안녕하세요'), 'already-ko');
  assert.equal(decideSelection('hello'), 'translate');
  assert.equal(decideSelection('hello 안녕'), 'translate');
  assert.equal(decideSelection('  '), 'none');
  assert.equal(decideSelection('123'), 'none');
});

// Bracket notes (plan docs/plans/2026-11-08-notes-and-iphone-port.md, rules 4, 5 and 7).
test('decideBox: notes leave the text and come back with the decision', () => {
  assert.deepEqual(decideBox('내일 봐 [정중하게]'), { kind: 'translate', lang: 'en', text: '내일 봐', notes: ['정중하게'] });
  assert.deepEqual(decideBox('[formal] ru: 안녕'), { kind: 'translate', lang: 'ru', text: '안녕', notes: ['formal'] });
  assert.deepEqual(decideBox('see you [formal]'), { kind: 'polish', text: 'see you', notes: ['formal'] });
  assert.deepEqual(decideBox('123 [as words]'), { kind: 'polish', text: '123', notes: ['as words'] }); // a note always runs
  assert.deepEqual(decideBox('see you [1]'), { kind: 'polish', text: 'see you [1]' }); // digits only: text
  assert.deepEqual(decideBox('안녕 [fr:로 하지 마]'), { kind: 'translate', lang: 'en', text: '안녕', notes: ['fr:로 하지 마'] });
  assert.deepEqual(decideBox('see you [짧게]'), { kind: 'polish', text: 'see you', notes: ['짧게'] }); // Hangul in a note only
});

test('decideBox: notes only is its own case', () => {
  assert.deepEqual(decideBox('[formal] [short]'), { kind: 'notes-only' });
});

test('decideSelection never reads notes: someone else wrote the text', () => {
  assert.equal(decideSelection('[참고] hello'), 'translate');
  assert.equal(decideSelection('[note]'), 'translate');
});
