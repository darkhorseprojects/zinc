import { $getNearestBlockElementAncestorOrThrow } from "@lexical/utils";
import {
  $createParagraphNode,
  $getRoot,
  $getSelection,
  $isElementNode,
  $isLineBreakNode,
  $isParagraphNode,
  $isRangeSelection,
  COMMAND_PRIORITY_HIGH,
  KEY_BACKSPACE_COMMAND,
  type ElementNode,
  type LexicalEditor,
  type LexicalNode,
  type LineBreakNode,
  type RangeSelection,
} from "lexical";
import { onCleanup, onMount } from "solid-js";
import { useLexicalEditor } from "./LexicalEditorProvider";

export function PromptBackspaceResetPlugin(props: { enabled: boolean }) {
  const editor = useLexicalEditor();
  let unregisterBackspace = () => {};

  onMount(() => {
    unregisterBackspace = registerPromptBackspaceReset(editor, () => props.enabled);
  });

  onCleanup(() => unregisterBackspace());

  return null;
}

export function registerPromptBackspaceReset(editor: LexicalEditor, enabled: () => boolean) {
  return editor.registerCommand(
    KEY_BACKSPACE_COMMAND,
    (event) => {
      if (!enabled()) return false;
      return resetPromptStyleBeforeBackspace(event);
    },
    COMMAND_PRIORITY_HIGH,
  );
}

export function resetPromptStyleBeforeBackspace(event: KeyboardEvent | null) {
  const selection = $getSelection();
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) return false;

  const block = blockForSelection();
  if (!block) return false;

  const softBreak = softBreakBeforeSelection(selection, block);
  if (softBreak) {
    return resetSoftBreakBoundary(event, block, softBreak);
  }

  if (!isAtBlockStart(selection, block) || !hasStyleToClear(selection, block)) return false;

  event?.preventDefault();
  const plainBlock = normalizeBlock(block);
  if (plainBlock) {
    plainBlock.selectStart();
    clearSelectionStyle();
  }
  return true;
}

function resetSoftBreakBoundary(event: KeyboardEvent | null, block: ElementNode, lineBreak: LineBreakNode) {
  if (!hasStyleToClear($getSelection(), block)) return false;

  event?.preventDefault();
  const paragraph = $createParagraphNode();
  paragraph.setFormat("");
  paragraph.setStyle("");
  paragraph.setTextFormat(0);
  paragraph.setTextStyle("");

  const movedNodes = lineBreak.getNextSiblings();
  if (movedNodes.length > 0) paragraph.append(...movedNodes);
  lineBreak.remove();

  topLevelBlock(block).insertAfter(paragraph);
  paragraph.selectStart();
  clearSelectionStyle();
  return true;
}

function blockForSelection(): ElementNode | null {
  const selection = $getSelection();
  if (!$isRangeSelection(selection)) return null;
  return $getNearestBlockElementAncestorOrThrow(selection.anchor.getNode());
}

function softBreakBeforeSelection(selection: RangeSelection, block: ElementNode): LineBreakNode | null {
  const anchorNode = selection.anchor.getNode();

  if ($isElementNode(anchorNode)) {
    const previousChild = anchorNode.getChildAtIndex(selection.anchor.offset - 1);
    return $isLineBreakNode(previousChild) && isDescendantOrSelf(previousChild.getParent(), block) ? previousChild : null;
  }

  if (selection.anchor.offset !== 0) return null;
  const previousSibling = anchorNode.getPreviousSibling();
  return $isLineBreakNode(previousSibling) && previousSibling.getParent() === block ? previousSibling : null;
}

function normalizeBlock(block: ElementNode | null): ElementNode | null {
  if (!block) return null;

  if ($isParagraphNode(block)) {
    block.setFormat("");
    block.setStyle("");
    block.setTextFormat(0);
    block.setTextStyle("");
    return block;
  }

  const paragraph = $createParagraphNode();
  if ($isElementNode(block)) paragraph.append(...block.getChildren());
  block.replace(paragraph);
  paragraph.setFormat("");
  paragraph.setStyle("");
  paragraph.setTextFormat(0);
  paragraph.setTextStyle("");
  return paragraph;
}

function hasStyleToClear(selection: ReturnType<typeof $getSelection>, block: ElementNode) {
  return !isPlainParagraph(block) || ($isRangeSelection(selection) && (selection.format !== 0 || selection.style !== ""));
}

function isPlainParagraph(block: ElementNode) {
  return (
    $isParagraphNode(block) &&
    block.getFormatType() === "" &&
    block.getStyle() === "" &&
    block.getTextFormat() === 0 &&
    block.getTextStyle() === ""
  );
}

function isAtBlockStart(selection: ReturnType<typeof $getSelection>, block: ElementNode) {
  if (!$isRangeSelection(selection)) return false;
  const firstDescendant = block.getFirstDescendant();
  if (!firstDescendant) return selection.anchor.offset === 0;
  return selection.anchor.key === firstDescendant.getKey() && selection.anchor.offset === 0;
}

function clearSelectionStyle() {
  const selection = $getSelection();
  if ($isRangeSelection(selection)) {
    selection.setFormat(0);
    selection.setStyle("");
  }
}

function topLevelBlock(block: ElementNode): LexicalNode {
  let node: LexicalNode = block;
  const root = $getRoot();
  while (node.getParent() !== root) {
    const parent = node.getParent();
    if (!parent) break;
    node = parent;
  }
  return node;
}

function isDescendantOrSelf(node: LexicalNode | null, ancestor: LexicalNode) {
  let current = node;
  while (current) {
    if (current === ancestor) return true;
    current = current.getParent();
  }
  return false;
}
