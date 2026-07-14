import { $generateNodesFromRawText, ElementNode, type LexicalNode, type NodeKey, type SerializedElementNode } from "lexical";

export type SerializedReasoningNode = SerializedElementNode;

export class ReasoningNode extends ElementNode {
  static getType(): string {
    return "reasoning";
  }

  static clone(node: ReasoningNode): ReasoningNode {
    return new ReasoningNode(node.__key);
  }

  static importJSON(serialized: SerializedReasoningNode): ReasoningNode {
    return new ReasoningNode().updateFromJSON(serialized);
  }

  exportJSON(): SerializedReasoningNode {
    return { ...super.exportJSON(), type: ReasoningNode.getType(), version: 1 };
  }

  createDOM(): HTMLElement {
    const dom = document.createElement("blockquote");
    dom.className = "zinc-reasoning";
    return dom;
  }

  updateDOM(): boolean {
    return false;
  }

  canBeEmpty(): true {
    return true;
  }

  isInline(): false {
    return false;
  }
}

export function $createReasoningNode(text = ""): ReasoningNode {
  const node = new ReasoningNode();
  if (text) node.append(...$generateNodesFromRawText(text));
  return node;
}

export function $isReasoningNode(node: LexicalNode | null | undefined): node is ReasoningNode {
  return node instanceof ReasoningNode;
}
