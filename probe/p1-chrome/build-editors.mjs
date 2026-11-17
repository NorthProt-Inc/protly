// Bundles editors.jsx with npm lexical/draft-js/slate installed in a scratch dir (EDITOR_MODULES, a node_modules
// folder; not part of the repo). Usage: EDITOR_MODULES=<dir>/node_modules node probe/p1-chrome/build-editors.mjs <out.js>
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const modules = process.env.EDITOR_MODULES;
if (!modules) throw new Error('set EDITOR_MODULES');
await build({
  entryPoints: [path.join(here, 'editors.jsx')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'chrome120',
  outfile: process.argv[2],
  nodePaths: [modules],
  define: { 'process.env.NODE_ENV': '"production"', global: 'window' },
  jsx: 'transform',
  logLevel: 'warning',
});
