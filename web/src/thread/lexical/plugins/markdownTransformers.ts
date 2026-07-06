import { TRANSFORMERS, type ElementTransformer } from "@lexical/markdown";
import { $createParagraphNode, type LexicalNode } from "lexical";
import { HorizontalRuleNode, $createHorizontalRuleNode, $isHorizontalRuleNode } from "~/thread/nodes";

export const HORIZONTAL_RULE_TRANSFORMER: ElementTransformer = {
  dependencies: [HorizontalRuleNode],
  export: (node) => ($isHorizontalRuleNode(node) ? "---" : null),
  regExp: /^(?:---|___|\*\*\*)\s*$/,
  replace: (parentNode, children, _match, isImport) => {
    const horizontalRule = $createHorizontalRuleNode();

    if (isImport) {
      parentNode.append(horizontalRule);
      return;
    }

    const nextParagraph = $createParagraphNode();
    appendChildren(nextParagraph, children);
    parentNode.replace(horizontalRule);
    horizontalRule.insertAfter(nextParagraph);
    nextParagraph.selectStart();
  },
  triggerOnEnter: true,
  type: "element",
};

export const ZINC_MARKDOWN_TRANSFORMERS = [
  ...TRANSFORMERS,
  HORIZONTAL_RULE_TRANSFORMER,
];

function appendChildren(parentNode: ReturnType<typeof $createParagraphNode>, children: LexicalNode[]) {
  if (children.length > 0) parentNode.append(...children);
}
