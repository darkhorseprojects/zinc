import { $getRoot, $getSelection, $isElementNode, $isLineBreakNode, $isRangeSelection, $isTextNode, COMMAND_PRIORITY_HIGH, KEY_ARROW_DOWN_COMMAND, KEY_ARROW_UP_COMMAND, KEY_BACKSPACE_COMMAND, KEY_DELETE_COMMAND, KEY_ENTER_COMMAND, type LexicalNode } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "./lexical";
import { $isEquationNode } from "./nodes";

export function BlockBoundaryPlugin(props: {
  enabled: boolean;
  source(): string;
  onSplit?(before: string, after: string): void;
  onMerge?(direction: "previous" | "next"): void;
  onNavigate?(direction: "previous" | "next"): void;
}) {
  const editor = useLexicalEditor(); let unregister = () => {};
  onMount(() => {
    unregister = merge(
      editor.registerCommand(KEY_ENTER_COMMAND, (event) => {
        if (!props.enabled || event?.shiftKey) return false; let offset = -1, allowed = false;
        editor.getEditorState().read(() => { const selection = $getSelection(); if (!$isRangeSelection(selection) || !selection.isCollapsed()) return; const top = selection.anchor.getNode().getTopLevelElement(); allowed = top?.getType() === "paragraph"; offset = sourceOffset(selection.anchor.getNode(), selection.anchor.offset); });
        if (!allowed || offset < 0) return false; event?.preventDefault(); const source = props.source(); props.onSplit?.(source.slice(0, offset), source.slice(offset)); return true;
      }, COMMAND_PRIORITY_HIGH),
      editor.registerCommand(KEY_BACKSPACE_COMMAND, (event) => boundary(event, "previous"), COMMAND_PRIORITY_HIGH),
      editor.registerCommand(KEY_DELETE_COMMAND, (event) => boundary(event, "next"), COMMAND_PRIORITY_HIGH),
      editor.registerCommand(KEY_ARROW_UP_COMMAND, (event) => navigate(event, "previous"), COMMAND_PRIORITY_HIGH),
      editor.registerCommand(KEY_ARROW_DOWN_COMMAND, (event) => navigate(event, "next"), COMMAND_PRIORITY_HIGH),
    );
  });
  onCleanup(() => unregister());
  function boundary(event: KeyboardEvent | null, direction: "previous" | "next") { if (!props.enabled) return false; let at = false; editor.getEditorState().read(() => { const selection = $getSelection(); if (!$isRangeSelection(selection) || !selection.isCollapsed()) return; const offset = sourceOffset(selection.anchor.getNode(), selection.anchor.offset), length = props.source().length; at = direction === "previous" ? offset === 0 : offset === length; }); if (!at) return false; event?.preventDefault(); props.onMerge?.(direction); return true; }
  function navigate(event: KeyboardEvent | null, direction: "previous" | "next") { if (!props.enabled || !atVisualBoundary(editor.getRootElement(), direction)) return false; event?.preventDefault(); props.onNavigate?.(direction); return true; }
  return null;
}
function sourceOffset(anchor: LexicalNode, anchorOffset: number) { let offset = 0, found = false; const walk = (node: LexicalNode) => { if (found) return; if ($isTextNode(node)) { if (node.is(anchor)) { offset += anchorOffset; found = true; } else offset += node.getTextContentSize(); return; } if ($isEquationNode(node)) { offset += node.getSource().length; return; } if ($isLineBreakNode(node)) { offset++; return; } if ($isElementNode(node)) node.getChildren().forEach(walk); }; $getRoot().getChildren().forEach(walk); return offset; }
function atVisualBoundary(root: HTMLElement | null, direction: "previous" | "next") { const selection = root?.ownerDocument.getSelection(); if (!root || !selection?.rangeCount || !selection.isCollapsed || !root.contains(selection.anchorNode)) return false; const range = selection.getRangeAt(0).cloneRange(); range.collapse(true); const caret = range.getClientRects()[0] ?? range.getBoundingClientRect(), bounds = root.getBoundingClientRect(), line = Number.parseFloat(getComputedStyle(root).lineHeight) || 24, tolerance = line * .45; return direction === "previous" ? caret.top <= bounds.top + tolerance : caret.bottom >= bounds.bottom - tolerance; }
function merge(...values: Array<() => void>) { return () => values.forEach((value) => value()); }
