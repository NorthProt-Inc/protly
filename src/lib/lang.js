const HANGUL = /[ᄀ-ᇿ㄰-㆏가-힯]/;
const HANGUL_G = /[ᄀ-ᇿ㄰-㆏가-힯]/g;

// Each run of consecutive Hangul in s.
export const hangulRuns = (s) => s.match(/[ᄀ-ᇿ㄰-㆏가-힯]+/g) ?? [];

export function hasHangul(s) {
  return HANGUL.test(s);
}

// Hangul present and no letters from any other script.
export function isKoreanOnly(s) {
  return hasHangul(s) && !/\p{L}/u.test(s.replace(HANGUL_G, ''));
}

// Target language for an incoming message, or null if it stays as is.
// otherTarget is the per-thread toggle for non-English languages: 'ko' | 'en'.
export function incomingTarget(srcLang, otherTarget) {
  if (srcLang === 'ko') return null;
  if (srcLang === 'en') return 'ko';
  return otherTarget;
}

export function resolveOutputLang(thread) {
  if (thread.outputLang && thread.outputLang !== 'auto') return thread.outputLang;
  if (thread.partnerLang && thread.partnerLang !== 'ko') return thread.partnerLang;
  return 'en';
}

// results: oldest first, each { from: 'me' | 'partner', src_lang }.
export function latestPartnerLang(results) {
  for (let i = results.length - 1; i >= 0; i--) {
    const r = results[i];
    // und: emoji only, or a code the parser refused. Neither says which language to answer in.
    if (r.from === 'partner' && r.src_lang && r.src_lang !== 'ko' && r.src_lang !== 'und') return r.src_lang;
  }
  return null;
}

// Picker order: the common ones first, then the rest by name. Codes are ISO 639-1
// (yue has none, so it uses 639-3); the model can still write any language not listed.
export const LANG_NAMES = {
  ko: 'Korean', en: 'English', ru: 'Russian', es: 'Spanish', ja: 'Japanese',
  zh: 'Chinese', fr: 'French', de: 'German', uk: 'Ukrainian', pt: 'Portuguese',
  ar: 'Arabic', be: 'Belarusian', bn: 'Bengali', bg: 'Bulgarian', yue: 'Cantonese',
  hr: 'Croatian', cs: 'Czech', da: 'Danish', nl: 'Dutch', et: 'Estonian',
  fi: 'Finnish', ka: 'Georgian', el: 'Greek', he: 'Hebrew', hi: 'Hindi',
  hu: 'Hungarian', id: 'Indonesian', it: 'Italian', kk: 'Kazakh', lv: 'Latvian',
  lt: 'Lithuanian', ms: 'Malay', mn: 'Mongolian', no: 'Norwegian', fa: 'Persian',
  pl: 'Polish', pa: 'Punjabi', ro: 'Romanian', sr: 'Serbian', sk: 'Slovak',
  sv: 'Swedish', tl: 'Tagalog', th: 'Thai', tr: 'Turkish', ur: 'Urdu',
  uz: 'Uzbek', vi: 'Vietnamese',
};

export const langName = (code) => LANG_NAMES[code] || code;

const isCode = (c) => c !== 'ko' && c in LANG_NAMES;

// A span inside the draft: a lowercase code, not right after an ASCII letter or digit, then `:`, optional spaces and
// Hangul at once, so "ID: abc", "No: 3", "http:" and "10:30" never open one. A single `;` closes it and is dropped;
// a run of two or more (;; is a sweat emoticon) is text. With no closing `;` the span runs to the end.
const SPAN_OPEN = /(?<![A-Za-z0-9])([a-z]{2,3}):\s*(?=[ᄀ-ᇿ㄰-㆏가-힯])/g;
const SPAN_CLOSE = /(?<!;);(?!;)/g;

function tagSpans(s) {
  let out = '';
  let i = 0;
  for (;;) {
    SPAN_OPEN.lastIndex = i;
    let m;
    while ((m = SPAN_OPEN.exec(s)) && !isCode(m[1]));
    if (!m) break;
    const from = m.index + m[0].length;
    SPAN_CLOSE.lastIndex = from;
    const c = SPAN_CLOSE.exec(s);
    const to = c ? c.index : s.length;
    out += `${s.slice(i, m.index)}<${m[1]}>${s.slice(from, to)}</${m[1]}>`;
    i = c ? to + 1 : s.length;
  }
  return out + s.slice(i);
}

// "ru: 안녕" -> { lang: 'ru', text: '안녕' }: a leading prefix picks the whole draft's language (any case, with or
// without a later `;`). Only known non-Korean codes count, so "ok:" stays text. Spans after it are tagged for the
// model: "안녕 fr:고마워; 잘가" -> { lang: null, text: '안녕 <fr>고마워</fr> 잘가' } (the prompts explain the tags).
// Callers apply it to Korean drafts only, which keeps English such as "no: ..." (Norwegian) out of it.
export function parseLangPrefix(s) {
  const m = s.match(/^\s*([a-z]{2,3}):\s*/i);
  const code = m?.[1].toLowerCase();
  if (!code || !isCode(code)) return { lang: null, text: tagSpans(s) };
  return { lang: code, text: tagSpans(s.slice(m[0].length)) };
}
