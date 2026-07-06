import { ListItemNode, ListNode, registerList } from "@lexical/list";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "../LexicalEditorProvider";

export function ListPlugin() {
  const editor = useLexicalEditor();
  let unregister = () => {};

  onMount(() => {
    if (!editor.hasNodes([ListNode, ListItemNode])) {
      throw new Error("ListPlugin requires ListNode and ListItemNode to be registered.");
    }
    unregister = registerList(editor);
  });

  onCleanup(() => unregister());

  return null;
}
