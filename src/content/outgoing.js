import { initial, reduce } from '../lib/preview.js';
import { hasHangul, hasNotes } from '../lib/lang.js';
import { getComposerText, setComposerText } from './dom.js';
import { ask, getCurrent, getSite, contextFor, bannerFor } from './main.js';
import { flags } from '../lib/flags.js';
import { createCard } from '../ui/card.js';
import { showToast } from '../ui/toast.js';
import { errorText } from '../ui/errors.js';
import { trusted } from '../ui/trust.js';
import { commandListener, isUndoKey } from '../lib/command.js';

const HINTS = 'Enter send · Esc keep · Alt+Z undo · Alt+Enter deep';

const COMPOSE_ENTER_MS = 300; // a deferred IME Enter must be followed by compositionend within this window
const WRITE_SETTLE_MS = 50;   // editors such as Lexical commit DOM updates asynchronously
const norm = (s) => s.replace(/\s+/g, ' ').trim();
const isEnter = (e) => e.key === 'Enter' || e.code === 'Enter' || e.code === 'NumpadEnter';
const block = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };
// WhatsApp's loader puts a key relay on window before the page's own listeners (whatsapp/loader.js), so a blocked key
// never reaches them. Elsewhere, window directly.
const onKey = (type, f) => (globalThis.protlyEarlyKeys ? globalThis.protlyEarlyKeys[type].add(f) : window.addEventListener(type, f, true));
const offKey = (type, f) => (globalThis.protlyEarlyKeys ? globalThis.protlyEarlyKeys[type].delete(f) : window.removeEventListener(type, f, true));

// An Enter the user did not make (isTrusted false) never starts a translation. It is held whenever the user's own
// Enter would not simply send: Hangul or a bracket note in the box (or in any editable box when the composer selector
// is broken),
// English with Polish on, a translation or write in progress, or a preview only the user may confirm.
// sendsComposer(target): the site sends the box on an Enter from that target too (WhatsApp: a focused message).
export function holdUntrustedEnter(e, { composer: c, writing, mode, polish = false, sendsComposer = () => false }) {
  if (!isEnter(e) || e.shiftKey) return false;
  const box = c ? (c.contains(e.target) || sendsComposer(e.target) ? c : null) : (e.target?.isContentEditable || e.target?.getAttribute?.('contenteditable') === 'true' ? e.target : null);
  if (!box) return false;
  const text = box.innerText || box.textContent || '';
  // With Polish on, the user's own Enter on English polishes first; a synthetic one must not skip that.
  return writing || mode !== 'idle' || hasHangul(text) || hasNotes(text) || (polish && !!c && /\p{L}/u.test(text));
}

export function mountOutgoing(cur) {
  let state = initial();
  let enterAfterComposition = null; // { hard, at }
  let lastText = ''; // composer text in preview or kept; recorded if Instagram's Send button sends it
  let writing = false; // a composer write is queued or running: its input events are ours, and Enter/Esc/Alt+Z wait
  let checking = false; // the translation was written and is being checked: Enter/Esc/Alt+Z wait for the check
  let writeGen = 0;
  let writeChain = Promise.resolve();
  let srcText = ''; // composer text when the current translation was requested
  let composing = false;
  let escHeld = false; // protly took this Escape's keydown, so its keyup is not the page's either
  let dead = false;

  // This mount still owns the page: not torn down and the URL still shows its thread. Between a thread
  // switch and the next 500 ms tick, composer() already finds the NEW thread's box.
  const live = () => !dead && getCurrent() === cur && getSite().threadId() === cur.threadId;
  const composer = () => getSite().findComposer(document);
  const sendsComposer = (t) => !!getSite().sendsComposer?.(t);
  // Writes run one at a time; a newer write supersedes queued or settling older ones.
  const write = (c, s) => {
    const gen = ++writeGen;
    writing = true;
    writeChain = writeChain.then(async () => {
      if (gen !== writeGen || !live()) return false;
      return setComposerText(c, s, () => gen === writeGen && live());
    }).catch(() => false).finally(() => { if (gen === writeGen) writing = false; });
    return writeChain;
  };

  // Composer selector check (design: selector miss = inactive + badge).
  // Instagram can drop the composer for a moment (slow load, thread switch), so retry before warning.
  const checkComposer = (tries = 0) => {
    if (!live() || composer()) return;
    if (tries < 9) return void setTimeout(() => checkComposer(tries + 1), 1000);
    ask({ type: 'badge', text: '!', reason: `${getSite().name} message box not found` }).catch(() => {});
    console.warn('[protly] composer not found after 10 s; outgoing translation inactive');
  };
  setTimeout(checkComposer, 1000);

  // One card above the composer's row, so Instagram's own layout stays intact. Rebuilt if the row is replaced.
  let card = null;
  let cardRow = null;
  const cardFor = () => {
    const c = composer();
    if (!c) return null;
    const row = getSite().cardAnchor(c);
    if (!card || cardRow !== row) {
      card?.hide();
      card = createCard({ place: { before: row } });
      cardRow = row;
    }
    return card;
  };
  const say = (msg, error = false) => cardFor()?.message(msg, { error });
  const hideNote = () => card?.hide();

  // Language chip: remember the choice for the thread, then translate again.
  async function saveLang(lang) {
    const c = getCurrent();
    try {
      if (c) c.thread = await ask({ type: 'setThread', threadId: c.threadId, patch: { outputLang: lang } });
    } catch (err) {
      showToast(`Could not save the reply language: ${errorText(err)}`, { transient: true, error: true });
    }
    dispatch({ type: 'lang', lang });
  }

  function resetPreview() {
    dispatch({ type: 'reset' });
    hideNote();
    lastText = '';
  }

  async function apply(effect) {
    if (!live()) return; // a late result must never touch another thread's composer
    const c = composer();
    switch (effect.type) {
      case 'translate': {
        if (c) srcText = getComposerText(c);
        const verb = effect.kind === 'polish' ? 'Polishing' : 'Translating';
        cardFor()?.working(effect.profile === 'hard' ? `${verb} deeply` : verb);
        try {
          const cur2 = getCurrent();
          if (!cur2) throw new Error('thread closed');
          const notes = effect.notes.length ? { notes: effect.notes } : {};
          const r = effect.kind === 'polish'
            ? await ask({ type: 'polish', text: effect.korean, profile: effect.profile, ...notes })
            : await ask({
              type: 'outgoing', threadId: cur2.threadId, context: contextFor(getSite().readMessages(cur2.root)),
              korean: effect.korean, profile: effect.profile, lang: effect.lang, ...notes,
            });
          dispatch({ type: 'result', reqId: effect.reqId, ...r });
        } catch (e) {
          if (bannerFor(e)) showToast(bannerFor(e), { error: true });
          dispatch({ type: 'fail', reqId: effect.reqId, message: errorText(e) });
        }
        break;
      }
      case 'show': {
        if (!c) { resetPreview(); break; }
        // The draft changed while translating (typing, or Instagram's Send button sent it): drop the result.
        if (norm(getComposerText(c)) !== norm(srcText)) {
          dispatch({ type: 'reset' });
          say('The draft changed while translating, so the translation was dropped. Press Enter again.', true);
          break;
        }
        const korean = state.korean;
        checking = true; // until the write is checked, a key would keep or send text nobody has checked
        let ok;
        try {
          ok = await write(c, effect.translation);
          await new Promise((r) => setTimeout(r, WRITE_SETTLE_MS));
        } finally {
          checking = false;
        }
        if (!live() || state.mode !== 'preview') break; // reset or thread switch meanwhile
        if (!ok || norm(getComposerText(c)) !== norm(effect.translation)) {
          dispatch({ type: 'reset' });
          if (korean) await write(c, korean); // never leave an unpreviewed translation behind
          say('Could not write the translation into the message box. Nothing was sent.', true);
          break;
        }
        lastText = effect.translation;
        cardFor()?.preview({
          text: effect.back_translation,
          model: effect.model,
          deep: effect.profile === 'hard',
          ...(state.kind === 'polish' ? {} : { lang: effect.lang, onLang: saveLang }), // polish has no target language
          hints: HINTS,
        });
        break;
      }
      case 'restore':
        if (c) await write(c, effect.korean);
        hideNote();
        lastText = '';
        break;
      case 'keep': // the box keeps what it holds; the user edits it and presses Enter or Alt+T again
        hideNote();
        lastText = state.mode === 'kept' ? state.shown : '';
        break;
      case 'sent': {
        // Runs synchronously inside the Enter keydown, before Instagram reads and clears the composer.
        const cur2 = getCurrent();
        const sentText = c ? getComposerText(c).trim() : '';
        hideNote();
        lastText = '';
        if (cur2 && sentText) ask({ type: 'sent', threadId: cur2.threadId, text: sentText, korean: effect.korean }).catch(() => {});
        break;
      }
      case 'hold': // a draft of notes only, or a note typed into the translation: nothing runs, nothing is sent
        say(effect.message);
        break;
      case 'fail':
        if (c && effect.korean != null && norm(getComposerText(c)) !== norm(effect.korean)) await write(c, effect.korean);
        lastText = '';
        say(`Translation failed: ${effect.message}`, true);
        break;
    }
  }

  function dispatch(event) {
    const r = reduce(state, event);
    state = r.state;
    apply(r.effect);
    return r.effect;
  }

  // Composer emptied in preview or kept: Instagram's Send button sent it, or the user deleted it.
  function checkEmpty() {
    if (state.mode !== 'preview' && state.mode !== 'kept') return;
    const c = composer();
    if (!c || getComposerText(c).trim() !== '') return;
    const cur2 = getCurrent();
    if (cur2 && lastText.trim()) {
      ask({ type: 'sent', threadId: cur2.threadId, text: lastText.trim(), korean: state.korean }).catch(() => {});
    }
    resetPreview();
  }

  function onInput(e) {
    const c = composer();
    if (writing || (state.mode !== 'preview' && state.mode !== 'kept') || !c || !c.contains(e.target)) return;
    const t = getComposerText(c);
    if (t.trim()) lastText = t; else checkEmpty();
  }

  function onKeyDown(e) {
    if (!live()) return; // main.js guards Hangul Enter until the new thread's handler is mounted
    const cur2 = getCurrent();
    if (!cur2?.thread.enabled) return;
    const c = composer();
    if (!trusted(e)) { // a page script or another extension: never a billed translation, never an unconfirmed send
      if (holdUntrustedEnter(e, { composer: c, writing, mode: state.mode, polish: flags.polish, sendsComposer })) block(e);
      return;
    }

    // An Enter the site turns into a send of the box counts as an Enter in the box.
    if (!c || !(c.contains(e.target) || (isEnter(e) && sendsComposer(e.target)))) {
      // Composer selector broken: never let Hangul or a note go out untranslated by accident.
      const t = !c && isEnter(e) && !e.shiftKey && e.target?.isContentEditable ? e.target.innerText || e.target.textContent || '' : '';
      if (hasHangul(t) || hasNotes(t)) {
        block(e);
        showToast('Message box not recognised, so nothing was sent. The selectors need updating.', { error: true });
      }
      return;
    }

    // A write is landing or being checked: the composer does not yet match the state, so Enter/Esc/Alt+Z would act
    // on stale text.
    if ((writing || checking) && (e.key === 'Escape' || isEnter(e) || isUndoKey(e))) { block(e); return; }
    if (isEnter(e) && e.repeat) { block(e); return; } // a held Enter must not confirm a preview it never showed

    if (e.key === 'Escape') {
      const eff = dispatch({ type: 'esc' });
      escHeld = eff.type !== 'pass';
      if (escHeld) block(e);
      return;
    }
    if (isUndoKey(e)) {
      if (!e.isComposing && !composing && dispatch({ type: 'undo' }).type !== 'pass') block(e);
      return;
    }
    if (!isEnter(e) || e.shiftKey) return;

    // Korean IME: Enter mid-composition. Never let it reach Instagram while a translation is pending
    // or while the box holds Hangul (unless it is a Korean translation) or a note; handle the Enter once the
    // composition is committed.
    if (e.isComposing || composing) {
      if (state.mode === 'translating') { block(e); return; }
      const raw = getComposerText(c);
      if (hasNotes(raw) || (hasHangul(raw) && !((state.mode === 'preview' || state.mode === 'kept') && state.lang === 'ko'))) {
        block(e);
        enterAfterComposition = { hard: e.altKey, at: Date.now() };
      }
      return;
    }

    const eff = dispatch({ type: 'enter', text: getComposerText(c), hard: e.altKey, polish: flags.polish });
    // 'sent' lets the real Enter through so Instagram sends the composer text itself.
    if (eff.type !== 'pass' && eff.type !== 'sent') block(e);
  }

  function onKeyUp(e) {
    if (e.key === 'Escape' && escHeld) { escHeld = false; block(e); }
  }

  function onCompositionStart() { composing = true; }
  function onCompositionEnd() {
    composing = false;
    const pending = enterAfterComposition;
    enterAfterComposition = null;
    if (!pending || Date.now() - pending.at > COMPOSE_ENTER_MS) return;
    // Let the committed text land in the composer first.
    setTimeout(() => {
      const c = composer();
      if (!c || !live()) return;
      const ev = { type: 'enter', text: getComposerText(c), hard: pending.hard, polish: flags.polish };
      // The real Enter was blocked, so a deferred 'sent' or 'pass' would send nothing: ask for another Enter.
      const kind = reduce(state, ev).effect.type;
      if (kind === 'sent' || kind === 'pass') { say('Press Enter again to send.'); return; }
      dispatch(ev);
    }, 0);
  }

  // Alt+T: owned only while this thread is live, translation is on and focus is in the composer. A disabled thread
  // falls through to the generic path. The real Enter is never involved: `run` never sends.
  // Known gap, accepted: between a thread switch and this mount (up to ~10 s) no adapter owns the composer, so
  // Alt+T falls through to the generic path, which writes outside the sent tracking (no hover original).
  const onCommand = commandListener({
    owner: () => {
      if (!live() || !getCurrent()?.thread.enabled) return null;
      const c = composer();
      return c && c.contains(document.activeElement) ? c : null;
    },
    composing: () => composing,
    run: (c) => { if (live() && composer() === c) dispatch({ type: 'run', text: getComposerText(c) }); },
  });
  chrome.runtime.onMessage.addListener(onCommand);

  onKey('keydown', onKeyDown);
  onKey('keyup', onKeyUp);
  window.addEventListener('compositionstart', onCompositionStart, true);
  window.addEventListener('compositionend', onCompositionEnd, true);
  window.addEventListener('input', onInput, true);
  cur.onMutate.push(checkEmpty);
  cur.onThreadUpdate.push((t) => { if (!t.enabled && state.mode !== 'idle') resetPreview(); });
  cur.onTeardown.push(() => {
    offKey('keydown', onKeyDown);
    offKey('keyup', onKeyUp);
    window.removeEventListener('compositionstart', onCompositionStart, true);
    window.removeEventListener('compositionend', onCompositionEnd, true);
    window.removeEventListener('input', onInput, true);
    chrome.runtime.onMessage.removeListener(onCommand);
    resetPreview();
    dead = true;
  });
}
