import { $generateNodesFromRawText, ElementNode, type LexicalNode, type NodeKey, type SerializedElementNode } from "lexical";

export type SerializedErrorNode = SerializedElementNode;

export class ErrorNode extends ElementNode {
  static getType(): string {
    return "error";
  }

  static clone(node: ErrorNode): ErrorNode {
    return new ErrorNode(node.__key);
  }

  static importJSON(serialized: SerializedErrorNode): ErrorNode {
    return new ErrorNode().updateFromJSON(serialized);
  }

  exportJSON(): SerializedErrorNode {
    return { ...super.exportJSON(), type: ErrorNode.getType(), version: 1 };
  }

  createDOM(): HTMLElement {
    const dom = document.createElement("section");
    dom.className = "zinc-error";
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

export function $createErrorNode(text = ""): ErrorNode {
  const node = new ErrorNode();
  if (text) node.append(...$generateNodesFromRawText(text));
  return node;
}

export function $isErrorNode(node: LexicalNode | null | undefined): node is ErrorNode {
  return node instanceof ErrorNode;
}
