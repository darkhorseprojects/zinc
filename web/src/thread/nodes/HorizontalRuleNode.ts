import { ElementNode, type LexicalNode, type NodeKey, type SerializedLexicalNode } from "lexical";

export class HorizontalRuleNode extends ElementNode {
  static getType(): string { return "horizontalrule"; }
  static clone(node: HorizontalRuleNode): HorizontalRuleNode { return new HorizontalRuleNode(node.__key); }
  static importJSON(serializedNode: SerializedLexicalNode): HorizontalRuleNode { return $createHorizontalRuleNode(); }

  constructor(key?: NodeKey) {
    super(key);
  }

  exportJSON(): any {
    return {
      type: HorizontalRuleNode.getType(),
      version: 1,
      children: [],
      direction: null,
      format: "",
      indent: 0,
    };
  }
  createDOM(): HTMLElement {
    const dom = document.createElement("hr");
    dom.className = "thread-hr";
    return dom;
  }
  updateDOM(): boolean {
    return false;
  }
  getTextContent(): string {
    return "\n---\n";
  }
}

export function $createHorizontalRuleNode(): HorizontalRuleNode {
  return new HorizontalRuleNode();
}

export function $isHorizontalRuleNode(node: LexicalNode | null | undefined): node is HorizontalRuleNode {
  return node instanceof HorizontalRuleNode;
}
