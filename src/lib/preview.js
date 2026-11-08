import { hasHangul, hangulRuns, parseLangPrefix } from './lang.js';

// korean: the source text. The Korean draft (prefix included, so Alt+Z restores it), or the English draft being polished.
// kind: 'translate' | 'polish'. shown: the translation the box holds (kept while a re-run is in flight).
// mode 'kept': Esc accepted the translation; the card is closed and the user may edit it. Enter sends it with its
// source (for the sent record) unless the edit added Hangul the translation did not have.
export const initial = () => ({ mode: 'idle', kind: null, korean: null, profile: null, lang: null, shown: null, reqId: 0 });

const norm = (t) => (t ?? '').replace(/\s+/g, ' ').trim();

// lang: an explicit choice (chip or a re-run), else the draft's prefix, else null (the thread decides).
// rerun: the box still holds the shown translation, so Esc can keep it.
function translate(s, korean, profile, lang, rerun = false) {
  const reqId = s.reqId + 1;
  const p = parseLangPrefix(korean);
  return {
    state: { mode: 'translating', kind: 'translate', korean, profile, lang, shown: rerun ? s.shown : null, reqId },
    effect: { type: 'translate', kind: 'translate', reqId, korean: p.text, profile, lang: lang ?? p.lang },
  };
}

function polish(s, text, profile, rerun = false) {
  const reqId = s.reqId + 1;
  return {
    state: { mode: 'translating', kind: 'polish', korean: text, profile, lang: null, shown: rerun ? s.shown : null, reqId },
    effect: { type: 'translate', kind: 'polish', reqId, korean: text, profile, lang: null },
  };
}

const idle = (s) => ({ ...s, mode: 'idle', kind: null, korean: null, profile: null, lang: null, shown: null });

// Hangul in the text that the kept translation did not have (it may keep ㅋㅋ or a Korean name).
// A Korean target never counts: its output is all Hangul. Nor do runs of bare jamo (ㅋㅋㅋ, ㅠㅠ): nothing to translate.
const JAMO_ONLY = /^[ᄀ-ᇿ㄰-㆏]+$/;
const newHangul = (text, s) => s.lang !== 'ko'
  && hangulRuns(text).some((run) => !JAMO_ONLY.test(run) && !s.shown.includes(run));

export function reduce(s, e) {
  switch (e.type) {
    case 'enter': {
      const profile = e.hard ? 'hard' : 'outgoing';
      if (s.mode === 'translating') return { state: s, effect: { type: 'block' } };
      if (s.mode === 'preview') {
        // New draft: Hangul that is not the shown translation (which may keep ㅋㅋ or a Korean name).
        if (hasHangul(e.text) && s.lang !== 'ko' && norm(e.text) !== norm(s.shown)) return translate(s, e.text, profile, null);
        if (e.hard) return s.kind === 'polish' ? polish(s, s.korean, 'hard', true) : translate(s, s.korean, 'hard', s.lang, true);
        // Anything else is sent as is, an edit included: polish starts only from idle.
        return { state: idle(s), effect: { type: 'sent', korean: s.korean } };
      }
      if (s.mode === 'kept') {
        if (newHangul(e.text, s)) return translate(s, e.text, profile, null);
        return { state: idle(s), effect: { type: 'sent', korean: s.korean } }; // never re-polished on Enter: Alt+T does that
      }
      if (hasHangul(e.text)) return translate(s, e.text, profile, null);
      if (e.polish && /\p{L}/u.test(e.text)) return polish(s, e.text, profile);
      return { state: s, effect: { type: 'pass' } };
    }
    // Alt+T in the composer: translate or polish without sending. Explicit, so polish needs no toggle.
    case 'run': {
      if (s.mode !== 'idle' && s.mode !== 'kept') return { state: s, effect: { type: 'none' } };
      if (hasHangul(e.text)) return translate(s, e.text, 'outgoing', null);
      if (/\p{L}/u.test(e.text)) return polish(s, e.text, 'outgoing');
      return { state: s, effect: { type: 'none' } };
    }
    case 'result':
      if (s.mode !== 'translating' || e.reqId !== s.reqId) return { state: s, effect: { type: 'none' } };
      return {
        state: { ...s, mode: 'preview', lang: s.kind === 'polish' ? null : e.lang, shown: e.translation },
        effect: {
          type: 'show', translation: e.translation, back_translation: e.back_translation,
          profile: s.profile, lang: e.lang, model: e.model,
        },
      };
    case 'fail':
      if (s.mode !== 'translating' || e.reqId !== s.reqId) return { state: s, effect: { type: 'none' } };
      return { state: idle(s), effect: { type: 'fail', message: e.message, korean: s.korean } };
    case 'lang':
      if (s.mode !== 'preview') return { state: s, effect: { type: 'none' } };
      return translate(s, s.korean, s.profile, e.lang, true);
    // Esc keeps what the box holds now (the translation, or the draft while a first request is in flight) and drops
    // any result still on its way. Alt+Z ('undo') puts the source back, also after Esc kept the translation.
    case 'esc':
      if (s.mode === 'preview' || s.mode === 'translating') {
        if (s.shown == null) return { state: idle(s), effect: { type: 'keep' } }; // the box still holds the draft
        return { state: { ...idle(s), mode: 'kept', korean: s.korean, lang: s.lang, shown: s.shown }, effect: { type: 'keep' } };
      }
      return { state: s, effect: { type: 'pass' } };
    case 'undo':
      if (s.mode === 'preview' || s.mode === 'translating' || s.mode === 'kept') {
        return { state: idle(s), effect: { type: 'restore', korean: s.korean } };
      }
      return { state: s, effect: { type: 'pass' } };
    case 'reset':
      return { state: idle(s), effect: { type: 'none' } };
    default:
      return { state: s, effect: { type: 'none' } };
  }
}
