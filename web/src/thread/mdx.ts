import { $createCodeNode, CodeNode } from "@lexical/code";
import { $createHeadingNode, HeadingNode, QuoteNode } from "@lexical/rich-text";
import { ListNode, ListItemNode } from "@lexical/list";
import { LinkNode } from "@lexical/link";
import {
  $convertFromMarkdownString,
  $convertToMarkdownString,
  TRANSFORMERS,
  type MultilineElementTransformer,
  type Transformer,
} from "@lexical/markdown";
import { $getRoot, LineBreakNode, type LexicalEditor } from "lexical";
import { $createMdxComponentNode, $isMdxComponentNode, $createHorizontalRuleNode, $isHorizontalRuleNode, HorizontalRuleNode, MdxComponentNode } from "~/thread/nodes";

export const zincLexicalNodes = [
  HeadingNode,
  QuoteNode,
  CodeNode,
  ListNode,
  ListItemNode,
  LinkNode,
  LineBreakNode,
  HorizontalRuleNode,
  MdxComponentNode,
] as const;

/** `<Word ...>` open tag start, `</Word>` close tag end. Component blocks are always their own paragraph (never inline), so a line-anchored match is exact, not a heuristic. */
const COMPONENT_START = /^<([A-Za-z][\w.-]*)((?:\s+[\w-]+(?:=(?:"(?:[^"\\]|\\.)*"|\{[^}]*\}))?)*)\s*>$/;
const componentEnd = (tag: string) => new RegExp(`^</${tag}\\s*>$`);

const COMPONENT_TRANSFORMER: MultilineElementTransformer = {
  dependencies: [MdxComponentNode],
  export: (node) => ($isMdxComponentNode(node) ? node.getRaw() : null),
  regExpStart: COMPONENT_START,
  regExpEnd: { optional: true, regExp: /^<\/[A-Za-z][\w.-]*\s*>$/ },
  replace: (rootNode, _children, startMatch, endMatch, linesInBetween, isImport) => {
    if (!isImport || !linesInBetween) return false;
    const [, tag, attrs] = startMatch;
    if (!endMatch || !componentEnd(tag).test(endMatch[0])) return false;
    // regExpStart/regExpEnd each match a whole line, so the framework's leading and trailing
    // linesInBetween entries are always "" (the leftover text on the tag lines themselves, which is none).
    const body = linesInBetween.slice(1, -1).join("\n");
    rootNode.append($createMdxComponentNode(tag, attrs, body));
  },
  type: "multiline-element",
};

const HORIZONTAL_RULE_TRANSFORMER: Transformer = {
  dependencies: [HorizontalRuleNode],
  export: (node) => ($isHorizontalRuleNode(node) ? "---" : null),
  regExp: /^(?:---|___|\*\*\*)\s*$/,
  // parentNode is the paragraph $importBlocks pre-created for this line; replacing it (not
  // appending into it) is what makes the rule itself the top-level sibling node on export.
  replace: (parentNode) => {
    parentNode.replace($createHorizontalRuleNode());
  },
  triggerOnEnter: true,
  type: "element",
};

export const ZINC_MARKDOWN_TRANSFORMERS: Transformer[] = [...TRANSFORMERS, COMPONENT_TRANSFORMER, HORIZONTAL_RULE_TRANSFORMER];

export function importMdxToLexical(editor: LexicalEditor, source: string): void {
  editor.update(() => $convertFromMarkdownString(source, ZINC_MARKDOWN_TRANSFORMERS), { discrete: true });
}

export function exportLexicalToMdx(editor: LexicalEditor): string {
  let source = "";
  editor.getEditorState().read(() => {
    source = $convertToMarkdownString(ZINC_MARKDOWN_TRANSFORMERS);
  });
  return source;
}
