import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as lang from '../src/lib/lang.js';
import { hasHangul, isKoreanOnly, incomingTarget, resolveOutputLang, latestPartnerLang, parseLangPrefix } from '../src/lib/lang.js';

test('hasHangul', () => {
  assert.equal(hasHangul('hello'), false);
  assert.equal(hasHangul('ㅋㅋ ok'), true);
  assert.equal(hasHangul('안녕'), true);
});

test('isKoreanOnly ignores emoji, digits, punctuation', () => {
  assert.equal(isKoreanOnly('안녕 ㅋㅋ 😂 3시!'), true);
  assert.equal(isKoreanOnly('안녕 hi'), false);
  assert.equal(isKoreanOnly('😂'), false);
  assert.equal(isKoreanOnly('привет'), false);
});

test('incomingTarget', () => {
  assert.equal(incomingTarget('ko', 'en'), null);
  assert.equal(incomingTarget('en', 'en'), 'ko');
  assert.equal(incomingTarget('en', 'ko'), 'ko');
  assert.equal(incomingTarget('ru', 'en'), 'en');
  assert.equal(incomingTarget('ru', 'ko'), 'ko');
  assert.equal(incomingTarget('ja', 'ko'), 'ko');
});

test('resolveOutputLang', () => {
  assert.equal(resolveOutputLang({ outputLang: 'ru', partnerLang: 'en' }), 'ru');
  assert.equal(resolveOutputLang({ outputLang: 'auto', partnerLang: 'ru' }), 'ru');
  assert.equal(resolveOutputLang({ outputLang: 'auto', partnerLang: null }), 'en');
  assert.equal(resolveOutputLang({ outputLang: 'auto', partnerLang: 'ko' }), 'en');
});

test('latestPartnerLang picks last non-Korean partner message', () => {
  const r = [
    { from: 'partner', src_lang: 'en' },
    { from: 'me', src_lang: 'ru' },
    { from: 'partner', src_lang: 'ru' },
    { from: 'partner', src_lang: 'ko' },
  ];
  assert.equal(latestPartnerLang(r), 'ru');
  assert.equal(latestPartnerLang([]), null);
});

test('LANG_NAMES: lowercase codes, unique names, rest sorted by name', async () => {
  const { LANG_NAMES, langName } = await import('../src/lib/lang.js');
  const codes = Object.keys(LANG_NAMES);
  const names = Object.values(LANG_NAMES);
  assert.ok(codes.every((c) => /^[a-z]{2,3}$/.test(c)));
  assert.equal(new Set(names).size, names.length);
  const rest = names.slice(10);
  assert.deepEqual(rest, [...rest].sort());
  assert.equal(langName('vi'), 'Vietnamese');
  assert.equal(langName('xx'), 'xx');
});

test('parseLangPrefix: a known code picks the language and is dropped', () => {
  assert.deepEqual(parseLangPrefix('ru: 안녕'), { lang: 'ru', text: '안녕' });
  assert.deepEqual(parseLangPrefix('ja: 첫줄\n둘째 줄'), { lang: 'ja', text: '첫줄\n둘째 줄' });
});

test('parseLangPrefix: ko, unknown codes, a late prefix with no Korean after it and URLs stay text', () => {
  for (const s of ['ko: 안녕', 'ok: 안녕', '안녕 ru:', 'https://x.com 안녕']) {
    assert.deepEqual(parseLangPrefix(s), { lang: null, text: s });
  }
});

// Spans: from a mid-draft `fr:` up to a single `;` (plan docs/plans/2026-11-08-prefix-spans.md).
test('parseLangPrefix: a mid-draft code opens a tagged span that closes at a single ;', () => {
  const span = (s) => parseLangPrefix(s);
  assert.deepEqual(span('오늘 고마웠어 fr:정말 고마워; 다음에 또 보자'), { lang: null, text: '오늘 고마웠어 <fr>정말 고마워</fr> 다음에 또 보자' });
  assert.deepEqual(span('안녕 fr:고마워; 그리고 ja:잘가; 끝'), { lang: null, text: '안녕 <fr>고마워</fr> 그리고 <ja>잘가</ja> 끝' });
  assert.deepEqual(span('안녕 fr:고마워 잘가'), { lang: null, text: '안녕 <fr>고마워 잘가</fr>' }); // no ; runs to the end
  assert.deepEqual(span('안녕 fr:  고마워;'), { lang: null, text: '안녕 <fr>고마워</fr>' }); // spaces after the colon
  assert.deepEqual(span('고마워fr:안녕;'), { lang: null, text: '고마워<fr>안녕</fr>' }); // right after Hangul
  assert.deepEqual(span('안녕 fr:고마워 ja:잘가; 끝'), { lang: null, text: '안녕 <fr>고마워 ja:잘가</fr> 끝' }); // no nesting
});

test('parseLangPrefix: ;; and longer runs are text and do not close a span; a ; outside a span is text', () => {
  assert.deepEqual(parseLangPrefix('안녕 fr:미안;; 늦었어'), { lang: null, text: '안녕 <fr>미안;; 늦었어</fr>' });
  assert.deepEqual(parseLangPrefix('안녕 fr:고마워;;; 응'), { lang: null, text: '안녕 <fr>고마워;;; 응</fr>' });
  assert.deepEqual(parseLangPrefix('안녕 fr:고마워; ;'), { lang: null, text: '안녕 <fr>고마워</fr> ;' });
  assert.deepEqual(parseLangPrefix('안녕; 잘가'), { lang: null, text: '안녕; 잘가' });
});

test('parseLangPrefix: a leading prefix still means the whole draft, and spans can follow it', () => {
  assert.deepEqual(parseLangPrefix('ru: 미안;; 늦었어'), { lang: 'ru', text: '미안;; 늦었어' });
  assert.deepEqual(parseLangPrefix('ru: 안녕; 잘가'), { lang: 'ru', text: '안녕; 잘가' });
  assert.deepEqual(parseLangPrefix('ru: 안녕 fr:고마워;'), { lang: 'ru', text: '안녕 <fr>고마워</fr>' });
});

test('parseLangPrefix: mid-draft look-alikes stay text', () => {
  for (const s of ['x ID: abc 추가해줘', 'x UK: 런던', 'x No: 3', '링크 http://안녕', '10:30 만나', '안녕 ok:안녕',
    '안녕 ko:안녕', '안녕 fr: Bonjour', '안녕 abc:안녕']) {
    assert.deepEqual(parseLangPrefix(s), { lang: null, text: s }, s);
  }
});

test('parseLangPrefix: known false positive, a lowercase id: before Hangul opens Indonesian (previewed before sending)', () => {
  assert.deepEqual(parseLangPrefix('내 아이디 id:홍길동'), { lang: null, text: '내 아이디 <id>홍길동</id>' });
});

// Shared with the iPhone keyboard (ProtlyCore LanguagesTests and NotesTests read the same files), so the two parsers
// cannot drift. Plan: docs/plans/2026-11-08-notes-and-iphone-port.md.
const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));

test('parseLangPrefix matches the shared span cases', () => {
  for (const c of fixture('span-cases.json')) {
    assert.deepEqual(parseLangPrefix(c.draft), { lang: c.lang, text: c.text }, c.draft);
  }
});

test('splitNotes matches the shared note cases', { skip: !lang.splitNotes && 'splitNotes lands in Sprint S1' }, () => {
  for (const c of fixture('notes-cases.json')) {
    assert.deepEqual(lang.splitNotes(c.draft), { text: c.text, notes: c.notes }, `${c.why}: ${JSON.stringify(c.draft)}`);
  }
});
