import { DecoratorNode, type LexicalNode, type NodeKey, type SerializedLexicalNode } from "lexical";

export type ComponentStatus = "ok" | "error" | "pending" | "info";
export type TranscriptBlockKind = "command" | "source" | "error" | "note";

export type ReasoningDecorator = {
  kind: "Reasoning";
  nodeKey: NodeKey;
  text: string;
};

export type TranscriptBlockDecorator = {
  kind: "TranscriptBlock";
  nodeKey: NodeKey;
  blockKind: TranscriptBlockKind;
  status: ComponentStatus;
  label: string;
  body: string;
  command: string;
  stage: string;
  exit: number | null;
};

export type ThreadComponentDecorator = ReasoningDecorator | TranscriptBlockDecorator;

export type TranscriptBlockInput = {
  kind: TranscriptBlockKind;
  status?: ComponentStatus;
  label?: string;
  body?: string;
  command?: string;
  stage?: string;
  exit?: number | null;
};

type SerializedReasoningNode = SerializedLexicalNode & { text: string };
type SerializedTranscriptBlockNode = SerializedLexicalNode & TranscriptBlockInput & {
  status: ComponentStatus;
  label: string;
  body: string;
  command: string;
  stage: string;
  exit: number | null;
};

export class ReasoningNode extends DecoratorNode<ReasoningDecorator> {
  __text: string;

  static getType(): string { return "reasoning"; }
  static clone(node: ReasoningNode): ReasoningNode { return new ReasoningNode(node.__text, node.__key); }
  static importJSON(serializedNode: SerializedReasoningNode): ReasoningNode { return $createReasoningNode(serializedNode.text); }

  constructor(text: string, key?: NodeKey) {
    super(key);
    this.__text = text;
  }

  exportJSON(): SerializedReasoningNode { return { type: ReasoningNode.getType(), version: 1, text: this.getText() }; }
  createDOM(): HTMLElement { return componentDom("thread-reasoning-node"); }
  updateDOM(): boolean { return false; }
  decorate(): ReasoningDecorator { return { kind: "Reasoning", nodeKey: this.getKey(), text: this.getText() }; }
  getTextContent(): string { return this.getText(); }
  getText(): string { return this.getLatest().__text; }
  setText(text: string): void { this.getWritable().__text = text; }
  isInline(): false { return false; }
}

export class TranscriptBlockNode extends DecoratorNode<TranscriptBlockDecorator> {
  __kind: TranscriptBlockKind;
  __status: ComponentStatus;
  __label: string;
  __body: string;
  __command: string;
  __stage: string;
  __exit: number | null;

  static getType(): string { return "transcript-block"; }
  static clone(node: TranscriptBlockNode): TranscriptBlockNode {
    return new TranscriptBlockNode({
      kind: node.__kind,
      status: node.__status,
      label: node.__label,
      body: node.__body,
      command: node.__command,
      stage: node.__stage,
      exit: node.__exit,
    }, node.__key);
  }
  static importJSON(serializedNode: SerializedTranscriptBlockNode): TranscriptBlockNode {
    return $createTranscriptBlockNode(serializedNode);
  }

  constructor(input: TranscriptBlockInput, key?: NodeKey) {
    super(key);
    this.__kind = input.kind;
    this.__status = input.status ?? (input.kind === "error" ? "error" : "pending");
    this.__label = input.label ?? "";
    this.__body = input.body ?? "";
    this.__command = input.command ?? "";
    this.__stage = input.stage ?? "";
    this.__exit = input.exit ?? null;
  }

  exportJSON(): SerializedTranscriptBlockNode {
    const latest = this.getLatest();
    return {
      type: TranscriptBlockNode.getType(),
      version: 1,
      kind: latest.__kind,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
      command: latest.__command,
      stage: latest.__stage,
      exit: latest.__exit,
    };
  }

  createDOM(): HTMLElement { return componentDom("thread-transcript-block-node"); }
  updateDOM(): boolean { return false; }
  decorate(): TranscriptBlockDecorator {
    const latest = this.getLatest();
    return {
      kind: "TranscriptBlock",
      nodeKey: this.getKey(),
      blockKind: latest.__kind,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
      command: latest.__command,
      stage: latest.__stage,
      exit: latest.__exit,
    };
  }
  getTextContent(): string { return [this.getCommand(), this.getBody()].filter(Boolean).join("\n"); }
  getBlockKind(): TranscriptBlockKind { return this.getLatest().__kind; }
  getStatus(): ComponentStatus { return this.getLatest().__status; }
  getLabel(): string { return this.getLatest().__label; }
  getBody(): string { return this.getLatest().__body; }
  getCommand(): string { return this.getLatest().__command; }
  getStage(): string { return this.getLatest().__stage; }
  getExit(): number | null { return this.getLatest().__exit; }
  isInline(): false { return false; }
}

export function $createReasoningNode(text: string): ReasoningNode {
  return new ReasoningNode(text);
}

export function $createTranscriptBlockNode(input: TranscriptBlockInput): TranscriptBlockNode {
  return new TranscriptBlockNode(input);
}

export function $isReasoningNode(node: LexicalNode | null | undefined): node is ReasoningNode {
  return node instanceof ReasoningNode;
}

export function $isTranscriptBlockNode(node: LexicalNode | null | undefined): node is TranscriptBlockNode {
  return node instanceof TranscriptBlockNode;
}

function componentDom(className: string): HTMLElement {
  const element = document.createElement("div");
  element.className = className;
  element.contentEditable = "false";
  return element;
}
