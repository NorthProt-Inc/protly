import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initial, reduce } from '../src/lib/preview.js';

const run = (events, s = initial()) => {
  const effects = [];
  for (const e of events) { const r = reduce(s, e); s = r.state; effects.push(r.effect); }
  return { s, effects };
};

// idle -> translating -> preview for `korean`, returns the preview state
function toPreview(korean, { hard = false, lang = 'en' } = {}) {
  const a = reduce(initial(), { type: 'enter', text: korean, hard });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'T', back_translation: korean, lang, model: 'claude-sonnet-5-5' });
  return b.state;
}

test('non-Hangul Enter passes through', () => {
  const { s, effects } = run([{ type: 'enter', text: 'hello', hard: false }]);
  assert.equal(s.mode, 'idle');
  assert.deepEqual(effects[0], { type: 'pass' });
});

test('Hangul Enter starts translation; second Enter while pending is blocked', () => {
  const { s, effects } = run([
    { type: 'enter', text: '내일 봐', hard: false },
    { type: 'enter', text: '내일 봐', hard: false },
  ]);
  assert.equal(s.mode, 'translating');
  assert.equal(effects[0].type, 'translate');
  assert.equal(effects[0].korean, '내일 봐');
  assert.equal(effects[0].profile, 'outgoing');
  assert.equal(effects[0].lang, null);
  assert.deepEqual(effects[1], { type: 'block' });
});

test('result shows preview with model; Enter sends with Korean original', () => {
  const a = reduce(initial(), { type: 'enter', text: '내일 봐', hard: false });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'see u tmrw', back_translation: '내일 봐', lang: 'en', model: 'claude-sonnet-5-5' });
  assert.equal(b.state.mode, 'preview');
  assert.deepEqual(b.effect, { type: 'show', translation: 'see u tmrw', back_translation: '내일 봐', profile: 'outgoing', lang: 'en', model: 'claude-sonnet-5-5' });
  const c = reduce(b.state, { type: 'enter', text: 'see u tmrw!', hard: false });
  assert.equal(c.state.mode, 'idle');
  assert.deepEqual(c.effect, { type: 'sent', korean: '내일 봐' });
});

test('stale result is ignored', () => {
  const a = reduce(initial(), { type: 'enter', text: '가자', hard: false });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId + 99, translation: 'x', back_translation: 'y', lang: 'en', model: 'm' });
  assert.equal(b.state.mode, 'translating');
  assert.deepEqual(b.effect, { type: 'none' });
});

test('Alt+Enter outside preview uses hard profile', () => {
  const { effects } = run([{ type: 'enter', text: '가자', hard: true }]);
  assert.equal(effects[0].profile, 'hard');
});

test('Alt+Enter inside preview re-translates stored Korean with hard', () => {
  const p = toPreview('가자');
  const c = reduce(p, { type: 'enter', text: "let's go (edited)", hard: true });
  assert.equal(c.state.mode, 'translating');
  assert.equal(c.effect.type, 'translate');
  assert.equal(c.effect.korean, '가자');
  assert.equal(c.effect.profile, 'hard');
  assert.equal(c.effect.lang, 'en');
});

test('Hangul Enter in preview starts a new translation of the new text', () => {
  const p = toPreview('가자');
  const c = reduce(p, { type: 'enter', text: '밥 먹자', hard: false });
  assert.equal(c.state.mode, 'translating');
  assert.equal(c.state.korean, '밥 먹자');
  assert.equal(c.effect.type, 'translate');
  assert.equal(c.effect.korean, '밥 먹자');
  assert.equal(c.effect.profile, 'outgoing');
  assert.equal(c.effect.lang, null);
});

test('Hangul Enter in preview with a Korean target sends', () => {
  const p = toPreview('가자', { lang: 'ko' });
  const c = reduce(p, { type: 'enter', text: '가자고', hard: false });
  assert.deepEqual(c.effect, { type: 'sent', korean: '가자' });
});

test('language change in preview re-translates with same profile', () => {
  const p = toPreview('가자', { hard: true });
  const c = reduce(p, { type: 'lang', lang: 'ru' });
  assert.equal(c.effect.type, 'translate');
  assert.equal(c.effect.profile, 'hard');
  assert.equal(c.effect.lang, 'ru');
  assert.equal(c.effect.korean, '가자');
});

test('Esc in preview keeps the translation; Alt+Z restores Korean, also after Esc', () => {
  const k = reduce(toPreview('가자'), { type: 'esc' });
  assert.equal(k.state.mode, 'kept');
  assert.deepEqual(k.effect, { type: 'keep' });
  assert.deepEqual(reduce(k.state, { type: 'esc' }).effect, { type: 'pass' }); // the page's Esc again
  const u = reduce(toPreview('가자'), { type: 'undo' });
  assert.equal(u.state.mode, 'idle');
  assert.deepEqual(u.effect, { type: 'restore', korean: '가자' });
  const ku = reduce(k.state, { type: 'undo' });
  assert.equal(ku.state.mode, 'idle');
  assert.deepEqual(ku.effect, { type: 'restore', korean: '가자' });
});

// toPreview('가자') shows 'T'; a translation that keeps Hangul shows it here.
const kept = (shown, lang = 'en') => {
  const a = reduce(initial(), { type: 'enter', text: '지민아 가자 ㅋㅋ' });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: shown, back_translation: 'x', lang, model: 'm' });
  return reduce(b.state, { type: 'esc' }).state;
};

test('kept: Enter sends the translation, edited or not, with its Korean source; Polish never runs', () => {
  const s = kept("Let's go 지민 ㅋㅋ");
  for (const text of ["Let's go 지민 ㅋㅋ", "Let's go now 지민 ㅋㅋ", 'Go'] ) {
    const r = reduce(s, { type: 'enter', text, polish: true });
    assert.equal(r.state.mode, 'idle');
    assert.deepEqual(r.effect, { type: 'sent', korean: '지민아 가자 ㅋㅋ' });
  }
});

test('kept: Enter translates again only when the edit adds Hangul the translation did not have', () => {
  const r = reduce(kept("Let's go 지민 ㅋㅋ"), { type: 'enter', text: "Let's go 지민 ㅋㅋ 빨리" });
  assert.equal(r.effect.type, 'translate');
  assert.equal(r.effect.korean, "Let's go 지민 ㅋㅋ 빨리");
  // A Korean target is all Hangul: an edit to it is sent as is.
  assert.equal(reduce(kept('지민아 가자', 'ko'), { type: 'enter', text: '지민아 빨리 가자' }).effect.type, 'sent');
});

test('kept: Alt+T polishes English and translates Hangul; the chip and results do nothing', () => {
  const s = kept("Let's go");
  const p = reduce(s, { type: 'run', text: "Let's go now" });
  assert.equal(p.effect.kind, 'polish');
  assert.equal(p.effect.korean, "Let's go now");
  assert.equal(reduce(s, { type: 'run', text: "Let's go 빨리" }).effect.kind, 'translate');
  assert.deepEqual(reduce(s, { type: 'lang', lang: 'ja' }).effect, { type: 'none' });
});

test('Esc during a re-run keeps the translation the box still holds', () => {
  const p = toPreview('가자');
  const r = reduce(p, { type: 'enter', text: 'T', hard: true });
  assert.equal(r.state.mode, 'translating');
  const k = reduce(r.state, { type: 'esc' });
  assert.equal(k.state.mode, 'kept');
  assert.equal(k.state.shown, 'T');
  assert.deepEqual(reduce(k.state, { type: 'enter', text: 'T' }).effect, { type: 'sent', korean: '가자' });
  const l = reduce(reduce(p, { type: 'lang', lang: 'ja' }).state, { type: 'esc' });
  assert.equal(l.state.mode, 'kept');
});

test('Esc or Alt+Z while translating drops the late result', () => {
  for (const [key, effect] of [['esc', { type: 'keep' }], ['undo', { type: 'restore', korean: '가자' }]]) {
    const a = reduce(initial(), { type: 'enter', text: '가자', hard: false });
    const b = reduce(a.state, { type: key });
    assert.equal(b.state.mode, 'idle'); // the box still holds the draft: nothing to keep
    assert.deepEqual(b.effect, effect);
    const c = reduce(b.state, { type: 'result', reqId: a.effect.reqId, translation: 'go', back_translation: '가자', lang: 'en', model: 'm' });
    assert.equal(c.state.mode, 'idle');
    assert.deepEqual(c.effect, { type: 'none' });
  }
});

test('failure returns to idle and carries the Korean', () => {
  const a = reduce(initial(), { type: 'enter', text: '가자', hard: false });
  const b = reduce(a.state, { type: 'fail', reqId: a.effect.reqId, message: 'overloaded' });
  assert.equal(b.state.mode, 'idle');
  assert.deepEqual(b.effect, { type: 'fail', message: 'overloaded', korean: '가자' });
});

test('failed re-translate from preview still carries the Korean', () => {
  const p = toPreview('가자');
  const c = reduce(p, { type: 'enter', text: 'T', hard: true });
  const d = reduce(c.state, { type: 'fail', reqId: c.effect.reqId, message: 'host' });
  assert.deepEqual(d.effect, { type: 'fail', message: 'host', korean: '가자' });
});

test('Esc and Alt+Z in idle pass; reset always returns idle', () => {
  assert.deepEqual(reduce(initial(), { type: 'esc' }).effect, { type: 'pass' });
  assert.deepEqual(reduce(initial(), { type: 'undo' }).effect, { type: 'pass' });
  const a = reduce(initial(), { type: 'enter', text: '가자', hard: false });
  assert.equal(reduce(a.state, { type: 'reset' }).state.mode, 'idle');
});

test('preview Enter sends a translation that keeps Hangul (ㅋㅋ, names)', () => {
  const a = reduce(initial(), { type: 'enter', text: 'ㅋㅋㅋ 내일 보자', hard: false });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'ㅋㅋ see u tmrw', back_translation: 'ㅋㅋ 내일 봐', lang: 'en', model: 'm' });
  const c = reduce(b.state, { type: 'enter', text: ' ㅋㅋ  see u tmrw ', hard: false });
  assert.deepEqual(c.effect, { type: 'sent', korean: 'ㅋㅋㅋ 내일 보자' });
  assert.equal(c.state.mode, 'idle');
});

test('preview Enter with different Hangul text is a new draft', () => {
  const s = toPreview('내일 봐');
  const r = reduce(s, { type: 'enter', text: '아니 모레 봐', hard: false });
  assert.equal(r.effect.type, 'translate');
  assert.equal(r.effect.korean, '아니 모레 봐');
});

// Polish (English drafts, toolbar toggle) and the language prefix.
const polishPreview = (text = 'i think its good') => {
  const a = reduce(initial(), { type: 'enter', text, polish: true });
  return reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'I think it is good.', back_translation: '수정', model: 'claude-sonnet-5-5' }).state;
};

test('English Enter: passes with polish off, starts a polish with it on', () => {
  assert.equal(reduce(initial(), { type: 'enter', text: 'hi there' }).effect.type, 'pass');
  const r = reduce(initial(), { type: 'enter', text: 'hi there', polish: true });
  assert.equal(r.effect.type, 'translate');
  assert.equal(r.effect.kind, 'polish');
  assert.equal(r.effect.korean, 'hi there');
  assert.equal(r.effect.profile, 'outgoing');
});

test('a draft with no letters passes even with polish on', () => {
  for (const t of ['😂😂', '12:30']) assert.equal(reduce(initial(), { type: 'enter', text: t, polish: true }).effect.type, 'pass');
});

test('polish preview: lang stays null, Enter sends, an edit is sent as is', () => {
  const s = polishPreview();
  assert.equal(s.mode, 'preview');
  assert.equal(s.lang, null);
  assert.deepEqual(reduce(s, { type: 'enter', text: 'I think it is good.', polish: true }).effect, { type: 'sent', korean: 'i think its good' });
  assert.equal(reduce(s, { type: 'enter', text: 'I think it is great.', polish: true }).effect.type, 'sent');
});

test('polish preview: Alt+Z restores the English original, Alt+Enter re-polishes with hard', () => {
  const s = polishPreview();
  assert.deepEqual(reduce(s, { type: 'undo' }).effect, { type: 'restore', korean: 'i think its good' });
  const h = reduce(s, { type: 'enter', text: 'I think it is good.', hard: true, polish: true }).effect;
  assert.equal(h.kind, 'polish');
  assert.equal(h.profile, 'hard');
  assert.equal(h.korean, 'i think its good');
});

test('Hangul typed over a polish preview starts a translation', () => {
  const r = reduce(polishPreview(), { type: 'enter', text: '내일 보자', polish: true });
  assert.equal(r.effect.kind, 'translate');
  assert.equal(r.effect.korean, '내일 보자');
});

test('prefix: ru: picks the language for the request, Alt+Z restores the prefixed draft', () => {
  const a = reduce(initial(), { type: 'enter', text: 'ru: 안녕' });
  assert.equal(a.effect.lang, 'ru');
  assert.equal(a.effect.korean, '안녕');
  assert.equal(a.state.korean, 'ru: 안녕');
  assert.deepEqual(reduce(a.state, { type: 'undo' }).effect, { type: 'restore', korean: 'ru: 안녕' });
});

test('prefix: the chip overrides it', () => {
  const a = reduce(initial(), { type: 'enter', text: 'ru: 안녕' });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'Привет', back_translation: '안녕', lang: 'ru', model: 'm' });
  const c = reduce(b.state, { type: 'lang', lang: 'ja' });
  assert.equal(c.effect.lang, 'ja');
  assert.equal(c.effect.korean, '안녕');
});

test('run in idle: Hangul translates without sending, like Enter', () => {
  const { s, effects } = run([{ type: 'run', text: '내일 봐' }]);
  assert.equal(s.mode, 'translating');
  assert.equal(effects[0].type, 'translate');
  assert.equal(effects[0].kind, 'translate');
  assert.equal(effects[0].profile, 'outgoing');
  assert.equal(effects[0].korean, '내일 봐');
});

test('run in idle: a prefix picks the language', () => {
  const { effects } = run([{ type: 'run', text: 'ru: 안녕' }]);
  assert.equal(effects[0].lang, 'ru');
  assert.equal(effects[0].korean, '안녕');
});

test('run in idle: English is polished whatever the polish toggle says', () => {
  const { s, effects } = run([{ type: 'run', text: 'i has a question' }]);
  assert.equal(s.mode, 'translating');
  assert.equal(effects[0].kind, 'polish');
  assert.equal(effects[0].profile, 'outgoing');
  assert.equal(effects[0].korean, 'i has a question');
});

test('run in idle: no letters does nothing', () => {
  const { s, effects } = run([{ type: 'run', text: '123 🙂' }]);
  assert.equal(s.mode, 'idle');
  assert.deepEqual(effects[0], { type: 'none' });
});

test('run is ignored while translating and in preview', () => {
  const a = reduce(initial(), { type: 'run', text: '내일 봐' });
  const b = reduce(a.state, { type: 'run', text: '내일 봐' });
  assert.equal(b.state, a.state);
  assert.deepEqual(b.effect, { type: 'none' });
  const p = toPreview('내일 봐');
  const c = reduce(p, { type: 'run', text: 'T' });
  assert.equal(c.state, p);
  assert.deepEqual(c.effect, { type: 'none' });
});

test('a draft with a span sends the tagged text and no language; Alt+Z restores the raw draft', () => {
  const { effects } = run([{ type: 'enter', text: '안녕 fr:고마워; 잘가' }, { type: 'undo' }]);
  assert.equal(effects[0].korean, '안녕 <fr>고마워</fr> 잘가');
  assert.equal(effects[0].lang, null);
  assert.deepEqual(effects[1], { type: 'restore', korean: '안녕 fr:고마워; 잘가' });
});

// Kept mode, beyond the basics above.

test('kept: a late result or failure after Esc during a re-run is dropped and the kept translation stays', () => {
  const p = toPreview('가자');
  for (const rerun of [reduce(p, { type: 'enter', text: 'T', hard: true }), reduce(p, { type: 'lang', lang: 'ja' })]) {
    const k = reduce(rerun.state, { type: 'esc' });
    assert.equal(k.state.mode, 'kept');
    const reqId = rerun.effect.reqId;
    const late = reduce(k.state, { type: 'result', reqId, translation: 'Opus T', back_translation: '가자', lang: 'en', model: 'm' });
    assert.equal(late.state, k.state);
    assert.deepEqual(late.effect, { type: 'none' });
    const failed = reduce(k.state, { type: 'fail', reqId, message: 'host' });
    assert.equal(failed.state, k.state);
    assert.deepEqual(failed.effect, { type: 'none' });
    assert.deepEqual(reduce(k.state, { type: 'enter', text: 'T' }).effect, { type: 'sent', korean: '가자' });
  }
});

test('kept: a prefixed draft keeps its prefix for the sent record and for Alt+Z', () => {
  const a = reduce(initial(), { type: 'enter', text: 'ru: 안녕' });
  const b = reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation: 'Привет', back_translation: '안녕', lang: 'ru', model: 'm' });
  const k = reduce(b.state, { type: 'esc' }).state;
  assert.equal(k.mode, 'kept');
  assert.equal(k.lang, 'ru');
  assert.deepEqual(reduce(k, { type: 'enter', text: 'Привет!' }).effect, { type: 'sent', korean: 'ru: 안녕' });
  assert.deepEqual(reduce(k, { type: 'undo' }).effect, { type: 'restore', korean: 'ru: 안녕' });
});

test('kept: a polish preview kept by Esc sends with its English source', () => {
  const k = reduce(polishPreview(), { type: 'esc' });
  assert.equal(k.state.mode, 'kept');
  assert.deepEqual(reduce(k.state, { type: 'enter', text: 'I think it is great.', polish: true }).effect,
    { type: 'sent', korean: 'i think its good' });
  assert.equal(reduce(k.state, { type: 'enter', text: 'I think it is great. 진짜', polish: true }).effect.kind, 'translate');
});

test('kept: Hangul runs at the edge of the kept translation', () => {
  const s = kept('See you 지민 ㅋㅋ');
  const enter = (text) => reduce(s, { type: 'enter', text }).effect.type;
  assert.equal(enter('See you 민 ㅋ'), 'sent'); // a part of a kept run is not new
  assert.equal(enter('See you 지민 ㅋㅋ ㅋㅋ'), 'sent'); // a kept run repeated
  assert.equal(enter('See you 지민아 ㅋㅋ'), 'translate'); // a kept run grown into a new word
  assert.equal(enter('See you 지민 ㅎㅎ'), 'sent'); // bare jamo (laughter) is never new
  assert.equal(enter('See you 민지'), 'translate'); // the same syllables in another order
});

// Seeded, so a failure is reproducible.
function rng(seed) {
  return () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x80000000; };
}

test('kept: generated edits re-translate exactly when a Hangul word is not part of the kept translation', () => {
  const rand = rng(42);
  const pick = (xs) => xs[Math.floor(rand() * xs.length)];
  const shown = 'Hey 지민, see you at 홍대 ㅋㅋ';
  const s = kept(shown);
  const ko = kept('지민아 홍대에서 봐 ㅋㅋ', 'ko');
  const keptParts = ['지민', '지', '민', '홍대', '대', 'ㅋㅋ', 'ㅋ', 'ㅎㅎ', 'ㅠ']; // bare jamo is never new either
  const newParts = ['빨리', '지민아', '홍대입구', '내일', '민지'];
  const english = ['ok', 'see you', 'at 7', '!', 'tmrw', '🙂'];
  for (let i = 0; i < 300; i++) {
    const words = Array.from({ length: 1 + Math.floor(rand() * 5) }, () => pick(rand() < 0.5 ? english : keptParts));
    const old = words.join(' ');
    // Only kept parts and English: sent as is, edited or not.
    assert.deepEqual(reduce(s, { type: 'enter', text: old }).effect, { type: 'sent', korean: '지민아 가자 ㅋㅋ' }, old);
    // One new run anywhere: translate the whole text.
    words.splice(Math.floor(rand() * (words.length + 1)), 0, pick(newParts));
    const text = words.join(' ');
    const r = reduce(s, { type: 'enter', text, polish: rand() < 0.5 });
    assert.equal(r.effect.type, 'translate', text);
    assert.equal(r.effect.kind, 'translate', text);
    assert.equal(r.effect.korean, text);
    // A Korean target never re-translates, whatever the edit.
    assert.equal(reduce(ko, { type: 'enter', text }).effect.type, 'sent', text);
  }
});

test('kept: laughter or crying in bare jamo never counts as new Hangul', () => {
  const s = kept("Let's go 지민 ㅋㅋ");
  for (const text of ["Let's go 지민 ㅋㅋㅋㅋ", "Let's go 지민 ㅠㅠ", "Let's go ㅎㅎ"]) {
    assert.equal(reduce(s, { type: 'enter', text }).effect.type, 'sent', text);
  }
  assert.equal(reduce(s, { type: 'enter', text: "Let's go 지민 ㅋㅋ 빨리" }).effect.type, 'translate');
});

// Bracket notes (plan docs/plans/2026-11-08-notes-and-iphone-port.md, rules 3 to 8 and 12).
const NOTES_ONLY = 'Add the message too. [Brackets] are notes for protly.';
const NOTE_ON_TRANSLATION = 'Notes work on a new draft. Undo first, then add the note.';
const previewOf = (text, { polish = false, translation = 'T' } = {}) => {
  const a = reduce(initial(), { type: 'enter', text, polish });
  return reduce(a.state, { type: 'result', reqId: a.effect.reqId, translation, back_translation: 'b', lang: 'en', model: 'm' }).state;
};

test('notes: a Korean draft with a note translates the text and sends the notes; the state keeps the raw draft', () => {
  const r = reduce(initial(), { type: 'enter', text: '내일 보자 [좀 더 정중하게]' });
  assert.equal(r.effect.type, 'translate');
  assert.equal(r.effect.korean, '내일 보자');
  assert.deepEqual(r.effect.notes, ['좀 더 정중하게']);
  assert.equal(r.state.korean, '내일 보자 [좀 더 정중하게]');
  const plain = reduce(initial(), { type: 'enter', text: '내일 보자' });
  assert.deepEqual(plain.effect.notes, []);
});

test('notes: the prefix is read after leading notes', () => {
  const r = reduce(initial(), { type: 'enter', text: '[formal] ru: 안녕' });
  assert.equal(r.effect.lang, 'ru');
  assert.equal(r.effect.korean, '안녕');
  assert.deepEqual(r.effect.notes, ['formal']);
});

test('notes: an English draft with a note is polished on Enter even with the Polish switch off', () => {
  for (const text of ['see you [formal]', '123 [make it words]']) {
    const r = reduce(initial(), { type: 'enter', text, polish: false });
    assert.equal(r.effect.type, 'translate', text);
    assert.equal(r.effect.kind, 'polish', text);
    assert.equal(r.effect.korean, text.replace(/ \[.*\]$/, ''));
    assert.equal(r.state.korean, text);
  }
  assert.deepEqual(reduce(initial(), { type: 'enter', text: 'see you [1]', polish: false }).effect, { type: 'pass' });
  const run = reduce(initial(), { type: 'run', text: '123 [make it words]' }).effect;
  assert.deepEqual([run.kind, run.korean, run.notes], ['polish', '123', ['make it words']]);
});

test('notes: a draft of notes only runs nothing (Enter and Alt+T)', () => {
  for (const type of ['enter', 'run']) {
    const r = reduce(initial(), { type, text: '[formal] [short]', polish: true });
    assert.deepEqual(r.effect, { type: 'hold', message: NOTES_ONLY }, type);
    assert.equal(r.state.mode, 'idle');
    assert.equal(r.state.reqId, 0);
  }
});

test('notes: a note typed into a preview or a kept translation is held, Alt+Enter and Alt+T too', () => {
  const p = previewOf('내일 보자');
  const k = reduce(p, { type: 'esc' }).state;
  assert.equal(k.mode, 'kept');
  for (const [s, e] of [[p, { type: 'enter', text: 'T [shorter]' }], [p, { type: 'enter', text: 'T [shorter]', hard: true }],
    [p, { type: 'run', text: 'T [shorter]' }], [k, { type: 'enter', text: 'T [shorter]' }], [k, { type: 'run', text: 'T [shorter]' }]]) {
    const r = reduce(s, e);
    assert.deepEqual(r.effect, { type: 'hold', message: NOTE_ON_TRANSLATION }, `${s.mode} ${JSON.stringify(e)}`);
    assert.equal(r.state, s);
  }
});

test('notes: a new Korean draft typed over a preview or a kept translation runs, with its notes', () => {
  const p = previewOf('내일 보자');
  const k = reduce(p, { type: 'esc' }).state;
  for (const [s, e] of [[p, { type: 'enter', text: '[짧게] 새 초안' }], [k, { type: 'enter', text: '[짧게] 새 초안' }],
    [k, { type: 'run', text: '[짧게] 새 초안' }]]) {
    const r = reduce(s, e).effect;
    assert.equal(r.type, 'translate', `${s.mode} ${e.type}`);
    assert.equal(r.korean, '새 초안');
    assert.deepEqual(r.notes, ['짧게']);
  }
});

test('notes: a bracket the translation itself has is not a new note', () => {
  const p = previewOf('내일 보자', { translation: 'see you [tomorrow]' });
  assert.deepEqual(reduce(p, { type: 'enter', text: 'see you [tomorrow]' }).effect, { type: 'sent', korean: '내일 보자' });
  // Hangul inside such a bracket is no new draft: the decision reads the text without notes.
  const q = previewOf('내일 보자', { translation: 'see you [내일]' });
  assert.deepEqual(reduce(q, { type: 'enter', text: 'see you [내일] ok' }).effect, { type: 'sent', korean: '내일 보자' });
});

test('notes: re-runs keep the notes (Deep, the language chip, a polish Deep)', () => {
  const p = previewOf('내일 보자 [정중하게]');
  const deep = reduce(p, { type: 'enter', text: 'T', hard: true }).effect;
  assert.equal(deep.korean, '내일 보자');
  assert.deepEqual(deep.notes, ['정중하게']);
  const chip = reduce(p, { type: 'lang', lang: 'ja' }).effect;
  assert.deepEqual([chip.korean, chip.lang, chip.notes], ['내일 보자', 'ja', ['정중하게']]);
  const pp = previewOf('see you [formal]');
  const pd = reduce(pp, { type: 'enter', text: 'T', hard: true }).effect;
  assert.deepEqual([pd.kind, pd.korean, pd.notes], ['polish', 'see you', ['formal']]);
});

test('notes: Alt+Z restores the raw draft and the sent record keeps it', () => {
  const p = previewOf('내일 보자 [정중하게]');
  assert.deepEqual(reduce(p, { type: 'undo' }).effect, { type: 'restore', korean: '내일 보자 [정중하게]' });
  assert.deepEqual(reduce(reduce(p, { type: 'esc' }).state, { type: 'undo' }).effect, { type: 'restore', korean: '내일 보자 [정중하게]' });
  assert.deepEqual(reduce(p, { type: 'enter', text: 'T' }).effect, { type: 'sent', korean: '내일 보자 [정중하게]' });
});
