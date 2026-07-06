import { DecoratorNode, type EditorConfig, type LexicalEditor, type LexicalNode, type NodeKey, type SerializedLexicalNode } from "lexical";

export type MdxSourceDecorator = {
  kind: "MdxSource";
  nodeKey: NodeKey;
  source: string;
};

export type SerializedMdxSourceNode = SerializedLexicalNode & {
  source: string;
};

export class MdxSourceNode extends DecoratorNode<MdxSourceDecorator> {
  __source: string;

  static getType(): string {
    return "mdx-source";
  }

  static clone(node: MdxSourceNode): MdxSourceNode {
    return new MdxSourceNode(node.__source, node.__key);
  }

  static importJSON(serializedNode: SerializedMdxSourceNode): MdxSourceNode {
    return $createMdxSourceNode(serializedNode.source);
  }

  constructor(source: string, key?: NodeKey) {
    super(key);
    this.__source = source;
  }

  exportJSON(): SerializedMdxSourceNode {
    return {
      type: MdxSourceNode.getType(),
      version: 1,
      source: this.getSource(),
    };
  }

  createDOM(_config: EditorConfig, _editor: LexicalEditor): HTMLElement {
    const element = document.createElement("div");
    element.className = "mdx-source-node";
    element.contentEditable = "false";
    return element;
  }

  updateDOM(_previous: MdxSourceNode, _dom: HTMLElement): boolean {
    return false;
  }

  decorate(): MdxSourceDecorator {
    return {
      kind: "MdxSource",
      nodeKey: this.getKey(),
      source: this.getSource(),
    };
  }

  getTextContent(): string {
    return this.getSource();
  }

  getSource(): string {
    return this.getLatest().__source;
  }

  setSource(source: string): void {
    this.getWritable().__source = source;
  }

  isInline(): false {
    return false;
  }
}

export function $createMdxSourceNode(source: string): MdxSourceNode {
  return new MdxSourceNode(source);
}

export function $isMdxSourceNode(node: LexicalNode | null | undefined): node is MdxSourceNode {
  return node instanceof MdxSourceNode;
}
