import { createContext, onCleanup, useContext, type JSX } from "solid-js";
import type { LexicalEditor } from "lexical";

const LexicalEditorContext = createContext<LexicalEditor>();

export function LexicalComposer(props: {
  editor: LexicalEditor;
  children: JSX.Element;
}) {
  onCleanup(() => {
    props.editor.setRootElement(null);
  });

  return (
    <LexicalEditorContext.Provider value={props.editor}>
      {props.children}
    </LexicalEditorContext.Provider>
  );
}

export function useLexicalEditor(): LexicalEditor {
  const editor = useContext(LexicalEditorContext);
  if (!editor) throw new Error("Lexical editor is missing");
  return editor;
}
