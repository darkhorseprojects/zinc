import { DecoratorNode, type LexicalNode, type NodeKey, type SerializedLexicalNode } from "lexical";

export type ComponentStatus = "ok" | "error" | "pending" | "info";

export type ReasoningDecorator = {
  kind: "Reasoning";
  nodeKey: NodeKey;
  text: string;
};

export type CommandDecorator = {
  kind: "Command";
  nodeKey: NodeKey;
  cmd: string;
  exit: number | null;
  status: ComponentStatus;
  label: string;
  body: string;
};

export type ErrorDecorator = {
  kind: "Error";
  nodeKey: NodeKey;
  stage: string;
  status: ComponentStatus;
  label: string;
  body: string;
};

export type SourceDecorator = {
  kind: "Source";
  nodeKey: NodeKey;
  status: ComponentStatus;
  label: string;
  body: string;
};

export type ThreadComponentDecorator =
  | ReasoningDecorator
  | CommandDecorator
  | ErrorDecorator
  | SourceDecorator;

type SerializedReasoningNode = SerializedLexicalNode & { text: string };

type SerializedCommandNode = SerializedLexicalNode & {
  cmd: string;
  exit: number | null;
  status: ComponentStatus;
  label: string;
  body: string;
};

type SerializedErrorNode = SerializedLexicalNode & {
  stage: string;
  status: ComponentStatus;
  label: string;
  body: string;
};

type SerializedSourceNode = SerializedLexicalNode & {
  status: ComponentStatus;
  label: string;
  body: string;
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

export class CommandNode extends DecoratorNode<CommandDecorator> {
  __cmd: string;
  __exit: number | null;
  __status: ComponentStatus;
  __label: string;
  __body: string;

  static getType(): string { return "command-node"; }
  static clone(node: CommandNode): CommandNode {
    const latest = node.getLatest();
    return new CommandNode({
      cmd: latest.__cmd,
      exit: latest.__exit,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    }, node.__key);
  }
  static importJSON(serializedNode: SerializedCommandNode): CommandNode {
    return $createCommandNode(serializedNode);
  }

  constructor(input: Omit<CommandDecorator, "kind" | "nodeKey">, key?: NodeKey) {
    super(key);
    this.__cmd = input.cmd;
    this.__exit = input.exit;
    this.__status = input.status;
    this.__label = input.label;
    this.__body = input.body;
  }

  exportJSON(): SerializedCommandNode {
    const latest = this.getLatest();
    return {
      type: CommandNode.getType(),
      version: 1,
      cmd: latest.__cmd,
      exit: latest.__exit,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }

  createDOM(): HTMLElement { return componentDom("thread-command-node"); }
  updateDOM(): boolean { return false; }
  decorate(): CommandDecorator {
    const latest = this.getLatest();
    return {
      kind: "Command",
      nodeKey: this.getKey(),
      cmd: latest.__cmd,
      exit: latest.__exit,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }
  getTextContent(): string { return [this.getCmd(), this.getBody()].filter(Boolean).join("\n"); }
  getCmd(): string { return this.getLatest().__cmd; }
  setCmd(cmd: string): void { this.getWritable().__cmd = cmd; }
  getExit(): number | null { return this.getLatest().__exit; }
  setExit(exit: number | null): void { this.getWritable().__exit = exit; }
  getStatus(): ComponentStatus { return this.getLatest().__status; }
  setStatus(status: ComponentStatus): void { this.getWritable().__status = status; }
  getLabel(): string { return this.getLatest().__label; }
  setLabel(label: string): void { this.getWritable().__label = label; }
  getBody(): string { return this.getLatest().__body; }
  setBody(body: string): void { this.getWritable().__body = body; }
  isInline(): false { return false; }
}

export class ErrorNode extends DecoratorNode<ErrorDecorator> {
  __stage: string;
  __status: ComponentStatus;
  __label: string;
  __body: string;

  static getType(): string { return "error-node"; }
  static clone(node: ErrorNode): ErrorNode {
    const latest = node.getLatest();
    return new ErrorNode({
      stage: latest.__stage,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    }, node.__key);
  }
  static importJSON(serializedNode: SerializedErrorNode): ErrorNode {
    return $createErrorNode(serializedNode);
  }

  constructor(input: Omit<ErrorDecorator, "kind" | "nodeKey">, key?: NodeKey) {
    super(key);
    this.__stage = input.stage;
    this.__status = input.status;
    this.__label = input.label;
    this.__body = input.body;
  }

  exportJSON(): SerializedErrorNode {
    const latest = this.getLatest();
    return {
      type: ErrorNode.getType(),
      version: 1,
      stage: latest.__stage,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }

  createDOM(): HTMLElement { return componentDom("thread-error-node"); }
  updateDOM(): boolean { return false; }
  decorate(): ErrorDecorator {
    const latest = this.getLatest();
    return {
      kind: "Error",
      nodeKey: this.getKey(),
      stage: latest.__stage,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }
  getTextContent(): string { return this.getBody(); }
  getStage(): string { return this.getLatest().__stage; }
  setStage(stage: string): void { this.getWritable().__stage = stage; }
  getStatus(): ComponentStatus { return this.getLatest().__status; }
  setStatus(status: ComponentStatus): void { this.getWritable().__status = status; }
  getLabel(): string { return this.getLatest().__label; }
  setLabel(label: string): void { this.getWritable().__label = label; }
  getBody(): string { return this.getLatest().__body; }
  setBody(body: string): void { this.getWritable().__body = body; }
  isInline(): false { return false; }
}

export class SourceNode extends DecoratorNode<SourceDecorator> {
  __status: ComponentStatus;
  __label: string;
  __body: string;

  static getType(): string { return "source-node"; }
  static clone(node: SourceNode): SourceNode {
    const latest = node.getLatest();
    return new SourceNode({
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    }, node.__key);
  }
  static importJSON(serializedNode: SerializedSourceNode): SourceNode {
    return $createSourceNode(serializedNode);
  }

  constructor(input: Omit<SourceDecorator, "kind" | "nodeKey">, key?: NodeKey) {
    super(key);
    this.__status = input.status;
    this.__label = input.label;
    this.__body = input.body;
  }

  exportJSON(): SerializedSourceNode {
    const latest = this.getLatest();
    return {
      type: SourceNode.getType(),
      version: 1,
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }

  createDOM(): HTMLElement { return componentDom("thread-source-node"); }
  updateDOM(): boolean { return false; }
  decorate(): SourceDecorator {
    const latest = this.getLatest();
    return {
      kind: "Source",
      nodeKey: this.getKey(),
      status: latest.__status,
      label: latest.__label,
      body: latest.__body,
    };
  }
  getTextContent(): string { return this.getBody(); }
  getStatus(): ComponentStatus { return this.getLatest().__status; }
  setStatus(status: ComponentStatus): void { this.getWritable().__status = status; }
  getLabel(): string { return this.getLatest().__label; }
  setLabel(label: string): void { this.getWritable().__label = label; }
  getBody(): string { return this.getLatest().__body; }
  setBody(body: string): void { this.getWritable().__body = body; }
  isInline(): false { return false; }
}

export function $createReasoningNode(text: string): ReasoningNode {
  return new ReasoningNode(text);
}

export function $createCommandNode(input: Omit<CommandDecorator, "kind" | "nodeKey">): CommandNode {
  return new CommandNode(input);
}

export function $createErrorNode(input: Omit<ErrorDecorator, "kind" | "nodeKey">): ErrorNode {
  return new ErrorNode(input);
}

export function $createSourceNode(input: Omit<SourceDecorator, "kind" | "nodeKey">): SourceNode {
  return new SourceNode(input);
}

export function $isReasoningNode(node: LexicalNode | null | undefined): node is ReasoningNode {
  return node instanceof ReasoningNode;
}

export function $isCommandNode(node: LexicalNode | null | undefined): node is CommandNode {
  return node instanceof CommandNode;
}

export function $isErrorNode(node: LexicalNode | null | undefined): node is ErrorNode {
  return node instanceof ErrorNode;
}

export function $isSourceNode(node: LexicalNode | null | undefined): node is SourceNode {
  return node instanceof SourceNode;
}

function componentDom(className: string): HTMLElement {
  const element = document.createElement("div");
  element.className = className;
  element.contentEditable = "false";
  return element;
}
