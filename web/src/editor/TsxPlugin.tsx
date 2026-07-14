import { $createCodeNode, $isCodeNode } from "@lexical/code-core";
import codeSvg from "@phosphor-icons/core/assets/regular/code.svg?raw";
import { $generateNodesFromRawText, $getNodeByKey, $getSelection, $isRangeSelection, $setSelection, type NodeKey } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { Icon } from "../shell/Icon";
import { useLexicalEditor } from "./lexical";
import { $createTsxPreviewNode, $isTsxPreviewNode, TsxPreviewNode } from "./nodes";
import { disposeTsxPreview } from "./nodes/TsxPreviewNode";

export function TsxPlugin(props: { enabled: boolean }) {
  const editor = useLexicalEditor(); let toggle!: HTMLButtonElement, root: HTMLElement | null = null, sourceKey: NodeKey | null = null; const disposers: Array<() => void> = [];
  onMount(() => {
    disposers.push(editor.registerMutationListener(TsxPreviewNode, (mutations) => { for (const [key, mutation] of mutations) if (mutation === "destroyed") disposeTsxPreview(key); }));
    if (!props.enabled) return; root = editor.getRootElement(); if (!root) return;
    const source = (event: Event) => { const key = (event as CustomEvent<{ key?: unknown }>).detail?.key; if (typeof key === "string") showSource(key); };
    root.addEventListener("zinc:tsx-source", source as EventListener); root.addEventListener("focusin", sync); root.addEventListener("focusout", sync); root.addEventListener("pointermove", sync); disposers.push(() => root?.removeEventListener("zinc:tsx-source", source as EventListener), () => root?.removeEventListener("focusin", sync), () => root?.removeEventListener("focusout", sync), () => root?.removeEventListener("pointermove", sync), editor.registerUpdateListener(() => queueMicrotask(sync)));
  });
  onCleanup(() => disposers.splice(0).forEach((dispose) => dispose()));

  function showSource(key: NodeKey) { editor.update(() => { const node = $getNodeByKey(key); if (!$isTsxPreviewNode(node)) return; const code = $createCodeNode("tsx"); code.append(...$generateNodesFromRawText(node.getSource())); $setSelection(null); node.replace(code); sourceKey = code.getKey(); code.selectStart(); }, { tag: "zinc-tsx-toggle" }); queueMicrotask(sync); }
  function showPreview(event: PointerEvent) { event.preventDefault(); const key = sourceKey; if (!key) return; editor.update(() => { const node = $getNodeByKey(key); if (!$isCodeNode(node) || node.getLanguage() !== "tsx") return; const preview = $createTsxPreviewNode(node.getTextContent()); $setSelection(null); node.replace(preview); sourceKey = null; }, { tag: "zinc-tsx-toggle" }); queueMicrotask(sync); }
  function sync() {
    let key: NodeKey | null = null; editor.getEditorState().read(() => { const selection = $getSelection(); if (!$isRangeSelection(selection)) return; const top = selection.anchor.getNode().getTopLevelElement(); if ($isCodeNode(top) && top.getLanguage() === "tsx") key = top.getKey(); }); sourceKey = key;
    if (!toggle) return; toggle.toggleAttribute("data-visible", Boolean(key));
  }
  return <button ref={toggle} class="tsx-source-toggle" type="button" tabIndex={-1} title="Preview" onPointerDown={showPreview}><Icon svg={codeSvg} size={15} /></button>;
}
