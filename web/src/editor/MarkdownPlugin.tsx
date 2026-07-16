import { animate, type JSAnimation } from "animejs";
import { $getNodeByKey, $getRoot, $getSelection, $isDecoratorNode, $isElementNode, $isLineBreakNode, $isRangeSelection, $isRootNode, $isTextNode, $parseSerializedNode, COMMAND_PRIORITY_LOW, SELECTION_CHANGE_COMMAND, type ElementNode, type LexicalNode, type NodeKey, type SerializedLexicalNode, type TextNode } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { duration, ease, motion } from "../styles/motion";
import { markdownToNodes, nodesToMarkdown } from "../markdown";
import { documentNodes, nodeText, type SerializedDocument, type SerializedNode } from "./codec";
import { hasActiveEquationSource, isActiveEquationSource } from "./EquationPlugin";
import { useLexicalEditor } from "./lexical";
import { $isEquationNode } from "./nodes";

export const MARKDOWN_NORMALIZE_TAG = "zinc-markdown-normalize";

export function MarkdownPlugin(props: { enabled: boolean }) {
  const editor = useLexicalEditor();
  const animations = new Map<HTMLElement, JSAnimation>();
  let reconciling = false, unregister = () => {};

  onMount(() => {
    if (!props.enabled) return;
    const decorate = () => decorateSyntax(editor, animations);
    const selection = editor.registerCommand(SELECTION_CHANGE_COMMAND, () => { queueMicrotask(decorate); return false; }, COMMAND_PRIORITY_LOW);
    const updates = editor.registerUpdateListener(({ dirtyElements, dirtyLeaves, editorState, tags }) => {
      decorate();
      if (tags.has(MARKDOWN_NORMALIZE_TAG) || hasActiveEquationSource(editor) || dirtyElements.size === 0 && dirtyLeaves.size === 0 || reconciling) return;
      const keys = editorState.read(() => dirtyTopLevels([...dirtyElements.keys(), ...dirtyLeaves]));
      if (!keys.length) return;
      reconciling = true;
      try { reconcile(editor, keys); } finally { reconciling = false; }
    });
    unregister = () => { selection(); updates(); };
    decorate();
  });

  onCleanup(() => {
    unregister();
    for (const animation of animations.values()) animation.cancel();
    animations.clear();
  });
  return null;
}

function reconcile(editor: ReturnType<typeof useLexicalEditor>, keys: NodeKey[]) {
  if (hasActiveEquationSource(editor)) return;
  let offset = 0;
  const plans: Array<{ key: NodeKey; target: SerializedNode }> = [];
  editor.getEditorState().read(() => {
    offset = selectionOffset();
    for (const key of keys) {
      const node = $getNodeByKey(key);
      if (!node || $isRootNode(node)) continue;
      const current = node.exportJSON() as unknown as SerializedNode, source = nodesToMarkdown([current]), targets = markdownToNodes(source);
      if (targets.length !== 1 || targets[0].type === "text" || targets[0].type === "linebreak" || JSON.stringify(strip(current)) === JSON.stringify(strip(targets[0]))) continue;
      plans.push({ key, target: targets[0] });
    }
  });
  if (!plans.length) return;
  editor.update(() => {
    for (const plan of plans) {
      const current = $getNodeByKey(plan.key); if (!current) continue;
      if (reconcileNode(current, plan.target)) continue;
      const replacement = $parseSerializedNode(plan.target as SerializedLexicalNode); assertRootChild($getRoot(), replacement, plan.target); current.replace(replacement);
    }
    selectOffset($getRoot().getChildren(), offset);
  }, { tag: MARKDOWN_NORMALIZE_TAG });
}

function dirtyTopLevels(keys: NodeKey[]) {
  const result = new Set<NodeKey>();
  for (const key of keys) {
    const node = $getNodeByKey(key); if (!node || $isRootNode(node)) continue;
    const top = node.getTopLevelElement(); if (top) result.add(top.getKey());
  }
  return [...result];
}

function reconcileChildren(parent: ElementNode, targets: SerializedNode[]) {
  for (let index = 0; index < targets.length; index++) {
    const target = targets[index], current = parent.getChildAtIndex(index);
    if (!current) { const created = $parseSerializedNode(target as SerializedLexicalNode); assertRootChild(parent, created, target); parent.append(created); continue; }
    if (reconcileNode(current, target)) continue;
    const replacement = $parseSerializedNode(target as SerializedLexicalNode); assertRootChild(parent, replacement, target); current.replace(replacement);
  }
  while (parent.getChildrenSize() > targets.length) parent.getLastChild()?.remove();
}

function assertRootChild(parent: ElementNode, node: LexicalNode, target: SerializedNode) { if ($isRootNode(parent) && !$isElementNode(node) && !$isDecoratorNode(node)) throw new Error(`Invalid root replacement: ${JSON.stringify({ target, actual: node.getType() })}`); }

function reconcileNode(current: LexicalNode, target: SerializedNode) {
  if (current.getType() !== target.type) return false;
  if ($isTextNode(current) && target.type === "text") {
    if (typeof target.text !== "string") return false;
    if (current.getTextContent() !== target.text) current.setTextContent(target.text);
    if (typeof target.format === "number" && current.getFormat() !== target.format) current.setFormat(target.format);
    if (typeof target.detail === "number" && current.getDetail() !== target.detail) current.setDetail(target.detail);
    if (typeof target.style === "string" && current.getStyle() !== target.style) current.setStyle(target.style);
    if (typeof target.mode === "string" && current.getMode() !== target.mode) current.setMode(target.mode as "normal" | "token" | "segmented");
    return true;
  }
  if ($isEquationNode(current) && typeof target.source === "string") {
    if (current.getSource() !== target.source) current.setSource(target.source);
    return sameMetadata(current.exportJSON() as unknown as SerializedNode, target, ["source"]);
  }
  if (!$isElementNode(current) || !Array.isArray(target.children)) return sameMetadata(current.exportJSON() as unknown as SerializedNode, target);
  if (!sameMetadata(current.exportJSON() as unknown as SerializedNode, target)) return false;
  if (current.getType() === "code" && current.getTextContent() === target.children.map(nodeText).join("")) return true;
  reconcileChildren(current, target.children.filter(record));
  return true;
}

function sameMetadata(current: SerializedNode, target: SerializedNode, ignored: string[] = []) {
  const omit = new Set(["children", "text", ...ignored]);
  return JSON.stringify(Object.fromEntries(Object.entries(current).filter(([key]) => !omit.has(key)))) === JSON.stringify(Object.fromEntries(Object.entries(target).filter(([key]) => !omit.has(key))));
}

function decorateSyntax(editor: ReturnType<typeof useLexicalEditor>, animations: Map<HTMLElement, JSAnimation>) {
  let caret = -1, source = "";
  const markers: Array<{ key: NodeKey; from: number; to: number }> = [];
  editor.getEditorState().read(() => {
    const selection = $getSelection();
    caret = $isRangeSelection(selection) ? sourceOffset(selection.anchor.getNode(), selection.anchor.offset) : -1;
    source = nodesToMarkdown(documentNodes(editor.getEditorState().toJSON() as unknown as SerializedDocument));
    let at = 0;
    const walk = (node: LexicalNode) => {
      if ($isTextNode(node)) {
        const next = at + node.getTextContentSize();
        if (node.isUnmergeable() && !isActiveEquationSource(editor, node.getKey())) markers.push({ key: node.getKey(), from: at, to: next });
        at = next;
        return;
      }
      if ($isEquationNode(node)) { at += node.getSource().length; return; }
      if ($isLineBreakNode(node)) { at++; return; }
      if ($isElementNode(node)) node.getChildren().forEach(walk);
    };
    $getRoot().getChildren().forEach(walk);
  });
  const ranges = syntaxOwners(source);
  for (const marker of markers) {
    const element = editor.getElementByKey(marker.key);
    if (!element) continue;
    element.dataset.markdownSyntax = "true";
    const owner = ranges.find((range) => range.markers.some(([from, to]) => from === marker.from && to === marker.to));
    reveal(element, Boolean(owner && caret >= owner.from && caret <= owner.to), animations);
  }
  for (const [element, animation] of animations) if (!element.isConnected) { animation.cancel(); animations.delete(element); }
}

function reveal(element: HTMLElement, active: boolean, animations: Map<HTMLElement, JSAnimation>) {
  const next = active ? "true" : "false";
  if (element.dataset.markdownSyntaxActive === next) return;
  element.dataset.markdownSyntaxActive = next;
  animations.get(element)?.cancel();
  const width = active ? Math.max(element.scrollWidth, textWidth(element)) : 0;
  const animation = animate(element, { width, opacity: active ? 1 : 0, duration: duration(motion.fast), ease: ease.standard });
  animations.set(element, animation);
}

function textWidth(element: HTMLElement) {
  const range = document.createRange();
  range.selectNodeContents(element);
  return range.getBoundingClientRect().width;
}

function syntaxOwners(source: string) {
  const result: Array<{ from: number; to: number; markers: Array<[number, number]> }> = [];
  const addPairs = (expression: RegExp, open: number, close: number) => { for (const match of source.matchAll(expression)) { const at = match.index ?? 0, end = at + match[0].length; result.push({ from: at, to: end, markers: [[at, at + open], [end - close, end]] }); } };
  addPairs(/\*\*[^\n]+?\*\*/g, 2, 2);
  addPairs(/~~[^\n]+?~~/g, 2, 2);
  addPairs(/(?<!\*)\*[^*\n]+?\*(?!\*)/g, 1, 1);
  addPairs(/`[^`\n]+?`/g, 1, 1);
  for (const match of source.matchAll(/\[[^\]\n]+\]\([^\n)]+\)/g)) {
    const at = match.index ?? 0, split = match[0].indexOf("](");
    result.push({ from: at, to: at + match[0].length, markers: [[at, at + 1], [at + split, at + split + 2], [at + match[0].length - 1, at + match[0].length]] });
  }
  const block = source.match(/^(#{1,6} |(?:[-*+] |\d+\. )|> )/);
  if (block) result.push({ from: 0, to: source.length, markers: [[0, block[0].length]] });
  return result;
}

function selectionOffset() {
  const selection = $getSelection();
  return $isRangeSelection(selection) ? sourceOffset(selection.anchor.getNode(), selection.anchor.offset) : 0;
}

function sourceOffset(anchor: LexicalNode, anchorOffset: number) {
  let offset = 0, found = false;
  const walk = (node: LexicalNode) => {
    if (found) return;
    if ($isTextNode(node)) {
      if (node.is(anchor)) { offset += anchorOffset; found = true; }
      else offset += node.getTextContentSize();
      return;
    }
    if ($isEquationNode(node)) { offset += node.getSource().length; return; }
    if ($isLineBreakNode(node)) { offset++; return; }
    if ($isElementNode(node)) node.getChildren().forEach(walk);
  };
  $getRoot().getChildren().forEach(walk);
  return offset;
}

function selectOffset(nodes: LexicalNode[], requested: number) {
  let remaining = requested;
  const entries: Array<{ text: TextNode; source: number } | { atomic: number }> = [];
  const collect = (node: LexicalNode) => {
    if ($isTextNode(node)) entries.push({ text: node, source: node.getTextContentSize() });
    else if ($isEquationNode(node)) entries.push({ atomic: node.getSource().length });
    else if ($isLineBreakNode(node)) entries.push({ atomic: 1 });
    else if ($isElementNode(node)) node.getChildren().forEach(collect);
  };
  nodes.forEach(collect);
  let previous: TextNode | null = null;
  for (const entry of entries) {
    if ("text" in entry) {
      if (remaining <= entry.source) { entry.text.select(Math.max(0, remaining), Math.max(0, remaining)); return; }
      remaining -= entry.source; previous = entry.text;
    } else {
      if (remaining <= entry.atomic) { previous?.selectEnd(); return; }
      remaining -= entry.atomic;
    }
  }
  previous?.selectEnd();
}

function strip(node: SerializedNode): SerializedNode { const value = { ...node }; delete value.__key; if (Array.isArray(value.children)) value.children = value.children.filter(record).map(strip); return value; }
function record(value: unknown): value is SerializedNode { return typeof value === "object" && value !== null && !Array.isArray(value); }
