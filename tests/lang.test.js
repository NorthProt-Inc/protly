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

// Notes beyond the shared cases (plan Part A rules 1 to 3).
test('splitNotes: closing punctuation takes no space, opening text and emoji do', () => {
  const { splitNotes } = lang;
  assert.deepEqual(splitNotes('Hi [x]!'), { text: 'Hi!', notes: ['x'] });
  assert.deepEqual(splitNotes('Really [x]?'), { text: 'Really?', notes: ['x'] });
  assert.deepEqual(splitNotes('(see [x]) ok'), { text: '(see) ok', notes: ['x'] });
  assert.deepEqual(splitNotes('one [x], two'), { text: 'one, two', notes: ['x'] });
  assert.deepEqual(splitNotes('a [x] (b)'), { text: 'a (b)', notes: ['x'] });
});

test('splitNotes: tabs count as spaces, line breaks stay (CRLF too)', () => {
  const { splitNotes } = lang;
  assert.deepEqual(splitNotes('a\t[x]\tb'), { text: 'a b', notes: ['x'] });
  assert.deepEqual(splitNotes('a\r\n[x]\r\nb'), { text: 'a\r\n\r\nb', notes: ['x'] });
  assert.deepEqual(splitNotes('a [x]\nb'), { text: 'a\nb', notes: ['x'] });
  assert.deepEqual(splitNotes('a\n[x] b'), { text: 'a\nb', notes: ['x'] });
});

test('splitNotes: any script counts as a letter; emoji, digits and symbols alone do not', () => {
  const { splitNotes } = lang;
  assert.deepEqual(splitNotes('a [ㅋ] b'), { text: 'a b', notes: ['ㅋ'] });
  assert.deepEqual(splitNotes('a [é] b'), { text: 'a b', notes: ['é'] });
  assert.deepEqual(splitNotes('a [кратко] b'), { text: 'a b', notes: ['кратко'] });
  for (const s of ['a [👍] b', 'a [3:30] b', 'a [!!] b']) assert.deepEqual(splitNotes(s), { text: s, notes: [] }, s);
});

test('splitNotes: a non-note bracket between two notes splits them into two runs', () => {
  assert.deepEqual(lang.splitNotes('a [x] [1] [y] b'), { text: 'a [1] b', notes: ['x', 'y'] });
});

test('splitNotes: a long unmatched [ stays text and returns at once', () => {
  const s = `[${'a'.repeat(50000)}`;
  const t = Date.now();
  assert.deepEqual(lang.splitNotes(s), { text: s, notes: [] });
  assert.ok(Date.now() - t < 200);
});

test('hasNotes and addsNote', () => {
  assert.equal(lang.hasNotes('a [x]'), true);
  assert.equal(lang.hasNotes('a [1]'), false);
  assert.equal(lang.addsNote('see you [formal]', 'see you'), true);
  assert.equal(lang.addsNote('see you [formal]', 'see you [formal]'), false); // the translation kept it
  assert.equal(lang.addsNote('see you', 'see you'), false);
  assert.equal(lang.addsNote('[x] see you', null), true);
});

// Spacing details pinned with the iPhone Notes.split (tower, 2026-11-08), so both parsers agree.
test('splitNotes: no space before exactly these closing marks; one space before anything else', () => {
  for (const c of ['.', ',', ';', ':', '!', '?', ')', ']', '}', '…', '。', '、', '！', '？', '，', '）', '」', '』']) {
    assert.deepEqual(lang.splitNotes(`a [x]${c}`), { text: `a${c}`, notes: ['x'] }, c);
  }
  for (const c of ['”', '»', '；', '：', '】', '(', '-', '👍']) {
    assert.deepEqual(lang.splitNotes(`a [x]${c}`), { text: `a ${c}`, notes: ['x'] }, c);
  }
});

test('splitNotes: spaces next to a note are JS \\s minus line breaks (NBSP, tabs, ideographic space)', () => {
  assert.deepEqual(lang.splitNotes('a [x]　b'), { text: 'a b', notes: ['x'] });
  assert.deepEqual(lang.splitNotes('a [x] b'), { text: 'a b', notes: ['x'] }); // a JS line terminator stays
});

test('splitNotes: note content may hold a line break', () => {
  assert.deepEqual(lang.splitNotes('x [a\nb] y'), { text: 'x y', notes: ['a\nb'] });
  assert.deepEqual(lang.splitNotes('x [\n a \n] y'), { text: 'x y', notes: ['a'] });
});

test('splitNotes: a draft without notes comes back unchanged, untrimmed; with notes the text is trimmed', () => {
  for (const s of ['  hi  ', ' [1] \n', '\n안녕\n', '']) assert.deepEqual(lang.splitNotes(s), { text: s, notes: [] }, JSON.stringify(s));
  assert.deepEqual(lang.splitNotes('\n hi [x] \n'), { text: 'hi', notes: ['x'] });
});

test('prefixTarget matches the shared prefix cases (a lowercase prefix translates a draft without Hangul)', () => {
  for (const c of fixture('prefix-target-cases.json')) {
    assert.equal(lang.prefixTarget(c.text), c.want, `${c.why}: ${JSON.stringify(c.text)}`);
  }
});
