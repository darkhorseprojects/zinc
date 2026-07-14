import { $createTextNode, $getNodeByKey, $getSelection, $isRangeSelection, $isTextNode, COMMAND_PRIORITY_LOW, SELECTION_CHANGE_COMMAND, type LexicalEditor, type NodeKey } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "./lexical";
import { $createEquationSourceNode, $isEquationNode, parseEquationSource } from "./nodes";

const active = new WeakMap<LexicalEditor, NodeKey>();
export function hasActiveEquationSource(editor: LexicalEditor) { return active.has(editor); }
export function isActiveEquationSource(editor: LexicalEditor, key: NodeKey) { return active.get(editor) === key; }

export function EquationPlugin(props: { editable: boolean }) {
  const editor = useLexicalEditor(); let root: HTMLElement | null = null, unregister = () => {};
  onMount(() => {
    root = editor.getRootElement(); if (!root) return;
    root.addEventListener("pointerdown", activate);
    unregister = editor.registerCommand(SELECTION_CHANGE_COMMAND, () => { queueMicrotask(finishIfExited); return false; }, COMMAND_PRIORITY_LOW);
  });
  onCleanup(() => { root?.removeEventListener("pointerdown", activate); unregister(); active.delete(editor); });

  function activate(event: PointerEvent) {
    if (!props.editable) return; const element = event.target instanceof Element ? event.target.closest<HTMLElement>(".zinc-equation") : null, key = element?.dataset.lexicalKey; if (!key) return;
    event.preventDefault();
    editor.update(() => {
      const node = $getNodeByKey(key); if (!$isEquationNode(node)) return;
      const text = $createTextNode(node.getSource()).toggleUnmergeable(); node.replace(text); active.set(editor, text.getKey()); text.select(Math.min(1, text.getTextContentSize()), Math.min(1, text.getTextContentSize()));
    }, { tag: "zinc-equation-source" });
  }

  function finishIfExited() {
    const key = active.get(editor); if (!key) return;
    let inside = false; editor.getEditorState().read(() => { const selection = $getSelection(); inside = Boolean($isRangeSelection(selection) && selection.anchor.key === key); });
    if (inside) return;
    editor.update(() => {
      const node = $getNodeByKey(key); active.delete(editor); if (!$isTextNode(node) || !node.isAttached() || !node.isUnmergeable()) return;
      const source = node.getTextContent(); if (parseEquationSource(source)) node.replace($createEquationSourceNode(source)); else node.toggleUnmergeable();
    }, { tag: "zinc-equation-source" });
  }
  return null;
}
