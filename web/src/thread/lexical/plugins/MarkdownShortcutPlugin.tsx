import { registerMarkdownShortcuts } from "@lexical/markdown";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "../LexicalEditorProvider";
import { ZINC_MARKDOWN_TRANSFORMERS } from "~/thread/mdx";

export function MarkdownShortcutPlugin() {
  const editor = useLexicalEditor();
  let unregister = () => {};

  onMount(() => {
    unregister = registerMarkdownShortcuts(editor, ZINC_MARKDOWN_TRANSFORMERS);
  });

  onCleanup(() => unregister());

  return null;
}
