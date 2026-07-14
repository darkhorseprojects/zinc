import { $getRoot, $getSelection, $isElementNode, $isRangeSelection, $isTextNode, $parseSerializedNode, COMMAND_PRIORITY_LOW, SELECTION_CHANGE_COMMAND, type LexicalNode, type NodeKey, type SerializedLexicalNode, type TextNode } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { markdownToNodes, nodesToMarkdown } from "../markdown";
import { documentFromNodes, documentNodes, type SerializedDocument, type SerializedNode } from "./codec";
import { useLexicalEditor } from "./lexical";
import { $isEquationNode } from "./nodes";
import { hasActiveEquationSource, isActiveEquationSource } from "./EquationPlugin";

const PARSE_TAG = "zinc-markdown-plan";

export function MarkdownPlugin(props: { enabled: boolean }) {
  const editor = useLexicalEditor(); let queued = false, unregister = () => {};
  onMount(() => {
    if (!props.enabled) return;
    const decorate = () => decorateSyntax(editor);
    const selection = editor.registerCommand(SELECTION_CHANGE_COMMAND, () => { queueMicrotask(decorate); return false; }, COMMAND_PRIORITY_LOW);
    const updates = editor.registerUpdateListener(({ dirtyElements, dirtyLeaves, tags }) => {
      decorate();
      if (tags.has(PARSE_TAG) || hasActiveEquationSource(editor) || dirtyElements.size === 0 && dirtyLeaves.size === 0 || queued) return;
      queued = true; queueMicrotask(() => { queued = false; reconcile(editor); });
    });
    unregister = () => { selection(); updates(); };
    decorate();
  });
  onCleanup(() => unregister()); return null;
}

function reconcile(editor: ReturnType<typeof useLexicalEditor>) {
  if (hasActiveEquationSource(editor)) return;
  let source = "", offset = 0, current: SerializedDocument;
  editor.getEditorState().read(() => { current = editor.getEditorState().toJSON() as unknown as SerializedDocument; source = nodesToMarkdown(documentNodes(current)); offset = selectionOffset(); });
  const parsed = documentFromNodes(markdownToNodes(source));
  if (signature(current!) === signature(parsed)) return;
  editor.update(() => {
    const root = $getRoot(); root.clear(); const nodes = documentNodes(parsed).map((node) => $parseSerializedNode(node as SerializedLexicalNode)); root.append(...nodes); selectOffset(nodes, offset);
  }, { tag: PARSE_TAG });
}

function decorateSyntax(editor: ReturnType<typeof useLexicalEditor>) {
  let caret = -1, source = "", markers: Array<{ key: NodeKey; from: number; to: number }> = [];
  editor.getEditorState().read(() => {
    const selection = $getSelection(); caret = $isRangeSelection(selection) ? sourceOffset(selection.anchor.getNode(), selection.anchor.offset) : -1;
    source = nodesToMarkdown(documentNodes(editor.getEditorState().toJSON() as unknown as SerializedDocument));
    let at = 0;
    const walk = (node: LexicalNode) => {
      if ($isTextNode(node)) { const next = at + node.getTextContentSize(); if (node.isUnmergeable() && !isActiveEquationSource(editor, node.getKey())) markers.push({ key: node.getKey(), from: at, to: next }); at = next; return; }
      if ($isEquationNode(node)) { at += node.getSource().length; return; }
      if ($isElementNode(node)) node.getChildren().forEach(walk);
    };
    $getRoot().getChildren().forEach(walk);
  });
  const ranges = syntaxOwners(source);
  for (const marker of markers) {
    const element = editor.getElementByKey(marker.key); if (!element) continue;
    element.dataset.markdownSyntax = "true";
    const owner = ranges.find((range) => range.markers.some(([from, to]) => from === marker.from && to === marker.to));
    element.toggleAttribute("data-markdown-syntax-active", Boolean(owner && caret >= owner.from && caret <= owner.to));
  }
}

function syntaxOwners(source: string) {
  const result: Array<{ from: number; to: number; markers: Array<[number, number]> }> = [];
  const addPairs = (expression: RegExp, open: number, close: number) => { for (const match of source.matchAll(expression)) { const at = match.index ?? 0, end = at + match[0].length; result.push({ from: at, to: end, markers: [[at, at + open], [end - close, end]] }); } };
  addPairs(/\*\*[^\n]+?\*\*/g, 2, 2); addPairs(/~~[^\n]+?~~/g, 2, 2); addPairs(/(?<!\*)\*[^*\n]+?\*(?!\*)/g, 1, 1); addPairs(/`[^`\n]+?`/g, 1, 1);
  for (const match of source.matchAll(/\[[^\]\n]+\]\([^\n)]+\)/g)) { const at = match.index ?? 0, split = match[0].indexOf("]("); result.push({ from: at, to: at + match[0].length, markers: [[at, at + 1], [at + split, at + split + 2], [at + match[0].length - 1, at + match[0].length]] }); }
  const block = source.match(/^(#{1,6} |(?:[-*+] |\d+\. )|> )/); if (block) result.push({ from: 0, to: source.length, markers: [[0, block[0].length]] });
  return result;
}

function selectionOffset() { const selection = $getSelection(); return $isRangeSelection(selection) ? sourceOffset(selection.anchor.getNode(), selection.anchor.offset) : 0; }
function sourceOffset(anchor: LexicalNode, anchorOffset: number) {
  let offset = 0, found = false;
  const walk = (node: LexicalNode) => { if (found) return; if ($isTextNode(node)) { if (node.is(anchor)) { offset += anchorOffset; found = true; } else offset += node.getTextContentSize(); return; } if ($isEquationNode(node)) { offset += node.getSource().length; return; } if ($isElementNode(node)) node.getChildren().forEach(walk); };
  $getRoot().getChildren().forEach(walk); return offset;
}
function selectOffset(nodes: LexicalNode[], requested: number) { let remaining = requested; const texts: TextNode[] = []; const collect = (node: LexicalNode) => { if ($isTextNode(node)) texts.push(node); else if ($isElementNode(node)) node.getChildren().forEach(collect); }; nodes.forEach(collect); for (const text of texts) { const size = text.getTextContentSize(); if (remaining <= size) { text.select(remaining, remaining); return; } remaining -= size; } texts.at(-1)?.selectEnd(); }
function signature(document: SerializedDocument) { return JSON.stringify(documentNodes(document).map(strip)); }
function strip(node: SerializedNode): SerializedNode { const value = { ...node }; delete value.__key; if (Array.isArray(value.children)) value.children = value.children.filter(record).map(strip); return value; }
function record(value: unknown): value is SerializedNode { return typeof value === "object" && value !== null && !Array.isArray(value); }
