import { hasHangul, isKoreanOnly, parseLangPrefix, splitNotes } from '../lib/lang.js';

const LETTER = /\p{L}/u;

// What Alt+T does with a text box. A prefix wins whatever the script (design section 6); this is the one place a
// prefix applies to non-Korean text, so "no: ..." in an English box becomes Norwegian. Intended.
// Bracket notes leave the text before any decision and come back as notes (only when there are some), so a re-run
// sends them again; a box of notes only is 'notes-only'. A note always runs: it never polishes nothing.
export function decideBox(raw) {
  const { text, notes } = splitNotes(raw);
  if (notes.length && !text) return { kind: 'notes-only' };
  const n = notes.length ? { notes } : {};
  const p = parseLangPrefix(text);
  if (p.lang) return p.text.trim() ? { kind: 'translate', lang: p.lang, text: p.text, ...n } : { kind: 'none' };
  if (hasHangul(text)) return { kind: 'translate', lang: 'en', text: p.text, ...n };
  if (notes.length || LETTER.test(text)) return { kind: 'polish', text, ...n };
  return { kind: 'none' };
}

// A selection outside any box goes to Korean. Someone else's text: brackets stay text.
export function decideSelection(text) {
  const t = (text ?? '').trim();
  if (!t) return 'none';
  if (isKoreanOnly(t)) return 'already-ko';
  return LETTER.test(t) ? 'translate' : 'none';
}
