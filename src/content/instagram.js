// Instagram DMs site adapter: every Instagram-specific choice the shared content core needs.
import { start as run } from './main.js';
import { threadIdFromPath } from '../lib/keys.js';
import { findViewerName } from './selectors.js';
import { findThreadRoot, findComposer, readMessages } from './dom.js';

export const SITE = {
  key: 'instagram', // flags.sites key
  name: 'Instagram', // badge and log wording
  threadId: () => threadIdFromPath(location.pathname), // sync; null = no thread open
  // null until the thread can be read: no viewer name means senders cannot be told apart (selector miss)
  findThreadRoot: (doc) => (findViewerName(doc) ? findThreadRoot(doc) : null),
  readMessages: (root) => readMessages(root), // [{ row, textEl, text, from: 'me'|'partner' }]
  findComposer,
  cardAnchor: (c) => c.closest('form, [role="group"]') || c.parentElement,
};

export const start = () => run(SITE);
