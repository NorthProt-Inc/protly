import { watchFlags, siteEnabled } from '../../lib/flags.js';
import { addFonts, fetchFonts } from '../../ui/fonts.js';
import { GSEL } from './selectors.js';
import { mountCompose, translate, keep, undoKey } from './compose.js';
import { commandListener, isUndoKey } from '../../lib/command.js';

const SCAN_MS = 300;

export async function start() {
  if (!(await siteEnabled('gmail'))) return; // switched off in the popup: mount nothing
  fetchFonts((p) => chrome.runtime.getURL(p)).then((f) => addFonts(document, f))
    .catch((e) => console.warn('[protly] fonts not loaded; using the monospace fallback', e));
  watchFlags();
  let timer = null;
  const scan = () => { timer = null; document.querySelectorAll(GSEL.body).forEach(mountCompose); };
  // Throttle, not debounce: Gmail mutates the page often enough that a debounce could never fire.
  new MutationObserver(() => { timer ??= setTimeout(scan, SCAN_MS); })
    .observe(document.body, { childList: true, subtree: true });
  scan();

  // In a compose body, Esc keeps protly's translation and Alt+Z undoes it. Only swallowed when protly acted.
  document.addEventListener('keydown', (e) => {
    const act = e.key === 'Escape' ? keep : isUndoKey(e) ? undoKey : null;
    if (!act || e.isComposing) return;
    const body = e.target?.closest?.(GSEL.body);
    if (!body || !act(body)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);

  // Alt+T arrives as a background command. The compose body owns it when focus is inside one.
  let composing = false;
  document.addEventListener('compositionstart', () => { composing = true; }, true);
  document.addEventListener('compositionend', () => { composing = false; }, true);
  chrome.runtime.onMessage.addListener(commandListener({
    owner: () => document.activeElement?.closest?.(GSEL.body) ?? null,
    composing: () => composing,
    run: (body) => { if (body.isConnected) translate(body); },
  }));
}
