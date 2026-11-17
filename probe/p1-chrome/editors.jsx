// Real editors for the P1 probe pages, bundled by build-editors.mjs into one IIFE.
// window.__probeMount(kind, el) turns el into that editor. window.__probe.model() returns the editor's own model as
// a list of blocks (each block's text, with '\n' for in-block line breaks): what the site would send.
import { createEditor, $getRoot, $getSelection } from 'lexical';
import { registerRichText } from '@lexical/rich-text';
import { registerPlainText } from '@lexical/plain-text';
import { registerHistory, createEmptyHistoryState } from '@lexical/history';
import React, { useState, useMemo } from 'react';
import { createRoot } from 'react-dom/client';
import { Editor, EditorState } from 'draft-js';
import { createEditor as createSlate, Node as SlateNode } from 'slate';
import { Slate, Editable, withReact } from 'slate-react';
import { withHistory } from 'slate-history';

const probe = { model: () => null, kind: null };
window.__probe = probe;

function mountLexical(el, plain) {
  el.setAttribute('role', 'textbox');
  const editor = createEditor({ namespace: 'probe', onError: (e) => { probe.lastError = String(e); console.error(e); } });
  editor.setRootElement(el);
  if (plain) registerPlainText(editor); else registerRichText(editor);
  registerHistory(editor, createEmptyHistoryState(), 300);
  probe.model = () => editor.getEditorState().read(() => $getRoot().getChildren().map((c) => c.getTextContent()));
  probe.modelFlat = () => editor.getEditorState().read(() => $getRoot().getTextContent());
  window.__lexical = editor;
  window.__lexicalSel = () => $getSelection(); // inside editor.read()
  window.__lexicalRootText = () => $getRoot().getTextContent();
}

function DraftBox({ onApi }) {
  const [state, setState] = useState(() => EditorState.createEmpty());
  onApi(() => state.getCurrentContent().getBlocksAsArray().map((b) => b.getText()));
  return <Editor editorState={state} onChange={setState} placeholder="" />;
}

function SlateBox({ onApi }) {
  const editor = useMemo(() => withHistory(withReact(createSlate())), []);
  const initial = useMemo(() => [{ type: 'paragraph', children: [{ text: '' }] }], []);
  onApi(() => editor.children.map((n) => SlateNode.string(n)));
  return <Slate editor={editor} initialValue={initial}><Editable role="textbox" /></Slate>;
}

window.__probeMount = (kind, el) => {
  probe.kind = kind;
  if (kind === 'lexical-rich') return mountLexical(el, false);
  if (kind === 'lexical-plain') return mountLexical(el, true);
  if (kind === 'draft') {
    createRoot(el).render(<DraftBox onApi={(f) => { probe.model = f; }} />);
    return;
  }
  if (kind === 'slate') {
    createRoot(el).render(<SlateBox onApi={(f) => { probe.model = f; }} />);
    return;
  }
  throw new Error(`unknown editor ${kind}`);
};
