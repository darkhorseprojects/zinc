import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "../LexicalEditorProvider";

export function HistoryPlugin(props: { delay?: number }) {
  const editor = useLexicalEditor();
  const historyState = createEmptyHistoryState();
  let unregister = () => {};

  onMount(() => {
    unregister = registerHistory(editor, historyState, props.delay ?? 300);
  });

  onCleanup(() => unregister());

  return null;
}
