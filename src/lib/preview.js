import { hasHangul, hangulRuns, parseLangPrefix, splitNotes, addsNote, NOTES_ONLY, NOTE_ON_TRANSLATION } from './lang.js';

// korean: the source text. The Korean draft (prefix and notes included, so Alt+Z restores them), or the English draft
// being polished. Each request splits the notes off it again, so a re-run keeps them.
// kind: 'translate' | 'polish'. shown: the translation the box holds (kept while a re-run is in flight).
// mode 'kept': Esc accepted the translation; the card is closed and the user may edit it. Enter sends it with its
// source (for the sent record) unless the edit added Hangul the translation did not have.
export const initial = () => ({ mode: 'idle', kind: null, korean: null, profile: null, lang: null, shown: null, reqId: 0 });

const norm = (t) => (t ?? '').replace(/\s+/g, ' ').trim();

// lang: an explicit choice (chip or a re-run), else the draft's prefix, else null (the thread decides).
// rerun: the box still holds the shown translation, so Esc can keep it.
function translate(s, korean, profile, lang, rerun = false) {
  const reqId = s.reqId + 1;
  const { text, notes } = splitNotes(korean);
  const p = parseLangPrefix(text);
  return {
    state: { mode: 'translating', kind: 'translate', korean, profile, lang, shown: rerun ? s.shown : null, reqId },
    effect: { type: 'translate', kind: 'translate', reqId, korean: p.text, notes, profile, lang: lang ?? p.lang },
  };
}

function polish(s, draft, profile, rerun = false) {
  const reqId = s.reqId + 1;
  const { text, notes } = splitNotes(draft);
  return {
    state: { mode: 'translating', kind: 'polish', korean: draft, profile, lang: null, shown: rerun ? s.shown : null, reqId },
    effect: { type: 'translate', kind: 'polish', reqId, korean: text, notes, profile, lang: null },
  };
}

const idle = (s) => ({ ...s, mode: 'idle', kind: null, korean: null, profile: null, lang: null, shown: null });

// Hangul in the text that the kept translation did not have (it may keep ㅋㅋ or a Korean name).
// A Korean target never counts: its output is all Hangul. Nor do runs of bare jamo (ㅋㅋㅋ, ㅠㅠ): nothing to translate.
const JAMO_ONLY = /^[ᄀ-ᇿ㄰-㆏]+$/;
const newHangul = (text, s) => s.lang !== 'ko'
  && hangulRuns(text).some((run) => !JAMO_ONLY.test(run) && !s.shown.includes(run));

// Held keys show a message and run nothing: a draft of notes only, or a note typed into a shown translation (no refine:
// Undo first, then add the note to the draft).
const hold = (s, message) => ({ state: s, effect: { type: 'hold', message } });
const shownMode = (s) => s.mode === 'preview' || s.mode === 'kept';
// A new Korean draft typed over the shown translation (not an edit of it): it runs, with its notes.
const freshDraft = (s, text) => (s.mode === 'kept'
  ? newHangul(text, s)
  : hasHangul(text) && s.lang !== 'ko' && norm(text) !== norm(s.shown));
// A note added to the shown translation itself is held: no refine.
const noteOnShown = (s, raw, text) => shownMode(s) && addsNote(raw, s.shown) && !freshDraft(s, text);

export function reduce(s, e) {
  switch (e.type) {
    case 'enter': {
      const profile = e.hard ? 'hard' : 'outgoing';
      if (s.mode === 'translating') return { state: s, effect: { type: 'block' } };
      // Mode decisions use the text without notes; the raw draft stays the source.
      const { text, notes } = splitNotes(e.text);
      if (noteOnShown(s, e.text, text)) return hold(s, NOTE_ON_TRANSLATION);
      if (s.mode === 'preview') {
        // New draft: Hangul that is not the shown translation (which may keep ㅋㅋ or a Korean name).
        if (freshDraft(s, text)) return translate(s, e.text, profile, null);
        if (e.hard) return s.kind === 'polish' ? polish(s, s.korean, 'hard', true) : translate(s, s.korean, 'hard', s.lang, true);
        // Anything else is sent as is, an edit included: polish starts only from idle.
        return { state: idle(s), effect: { type: 'sent', korean: s.korean } };
      }
      if (s.mode === 'kept') {
        if (freshDraft(s, text)) return translate(s, e.text, profile, null);
        return { state: idle(s), effect: { type: 'sent', korean: s.korean } }; // never re-polished on Enter: Alt+T does that
      }
      if (notes.length && !text) return hold(s, NOTES_ONLY);
      if (hasHangul(text)) return translate(s, e.text, profile, null);
      // A draft with a note never goes out as typed: polish it, Polish switch or not.
      if (notes.length || (e.polish && /\p{L}/u.test(text))) return polish(s, e.text, profile);
      return { state: s, effect: { type: 'pass' } };
    }
    // Alt+T in the composer: translate or polish without sending. Explicit, so polish needs no toggle.
    case 'run': {
      const { text, notes } = splitNotes(e.text);
      if (noteOnShown(s, e.text, text)) return hold(s, NOTE_ON_TRANSLATION);
      if (s.mode !== 'idle' && s.mode !== 'kept') return { state: s, effect: { type: 'none' } };
      if (notes.length && !text) return hold(s, NOTES_ONLY);
      if (hasHangul(text)) return translate(s, e.text, 'outgoing', null);
      if (notes.length || /\p{L}/u.test(text)) return polish(s, e.text, 'outgoing');
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
