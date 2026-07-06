import { HISTORY_MERGE_TAG, type EditorState, type LexicalEditor } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "../LexicalEditorProvider";

export function OnChangePlugin(props: {
  enabled?: boolean;
  ignoreHistoryMergeTagChange?: boolean;
  ignoreSelectionChange?: boolean;
  onChange: (editorState: EditorState, editor: LexicalEditor, tags: Set<string>) => void;
}) {
  const editor = useLexicalEditor();
  let unregister = () => {};

  onMount(() => {
    unregister = editor.registerUpdateListener(({ editorState, dirtyElements, dirtyLeaves, prevEditorState, tags }) => {
      if (props.enabled === false) return;
      if ((props.ignoreSelectionChange ?? true) && dirtyElements.size === 0 && dirtyLeaves.size === 0) return;
      if ((props.ignoreHistoryMergeTagChange ?? true) && tags.has(HISTORY_MERGE_TAG)) return;
      if (prevEditorState.isEmpty()) return;
      props.onChange(editorState, editor, tags);
    });
  });

  onCleanup(() => unregister());

  return null;
}
