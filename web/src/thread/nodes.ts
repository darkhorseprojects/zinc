import { DecoratorNode, ElementNode, type LexicalNode, type NodeKey, type SerializedLexicalNode } from "lexical";

/**
 * One generic component node for every `<Tag attr="x" attr={1}>body</Tag>` block the model or
 * user writes, known or custom. `tag`+`attrs`+`body` are the source of truth; `getRaw()` derives
 * the exact MDX source from them, so round-trip export is lossless and adding a new known
 * component is a rendering-registry concern (see thread/components/), never a node-class concern.
 */
export type MdxComponentDecorator = {
  kind: "MdxComponent";
  nodeKey: NodeKey;
  tag: string;
  props: Record<string, unknown>;
  body: string;
};

export type SerializedMdxComponentNode = SerializedLexicalNode & {
  tag: string;
  attrs: string;
  body: string;
};

export class MdxComponentNode extends DecoratorNode<MdxComponentDecorator> {
  __tag: string;
  __attrs: string;
  __body: string;

  static getType(): string {
    return "mdx-component";
  }

  static clone(node: MdxComponentNode): MdxComponentNode {
    const latest = node.getLatest();
    return new MdxComponentNode(latest.__tag, latest.__attrs, latest.__body, node.__key);
  }

  static importJSON(serialized: SerializedMdxComponentNode): MdxComponentNode {
    return $createMdxComponentNode(serialized.tag, serialized.attrs, serialized.body);
  }

  constructor(tag: string, attrs: string, body: string, key?: NodeKey) {
    super(key);
    this.__tag = tag;
    this.__attrs = attrs;
    this.__body = body;
  }

  exportJSON(): SerializedMdxComponentNode {
    const latest = this.getLatest();
    return { type: MdxComponentNode.getType(), version: 1, tag: latest.__tag, attrs: latest.__attrs, body: latest.__body };
  }

  createDOM(): HTMLElement {
    const element = document.createElement("div");
    element.className = "mdx-component-node";
    element.contentEditable = "false";
    return element;
  }

  updateDOM(): boolean {
    return false;
  }

  decorate(): MdxComponentDecorator {
    const latest = this.getLatest();
    return { kind: "MdxComponent", nodeKey: this.getKey(), tag: latest.__tag, props: parseAttrs(latest.__attrs), body: latest.__body };
  }

  /** Lexical's markdown exporter falls back to `getTextContent()` for any node it has no transformer for, which is exactly the raw MDX source for decorator nodes. */
  getTextContent(): string {
    return this.getRaw();
  }

  getRaw(): string {
    const latest = this.getLatest();
    return `<${latest.__tag}${latest.__attrs}>\n${latest.__body}\n</${latest.__tag}>`;
  }

  getTag(): string {
    return this.getLatest().__tag;
  }

  getBody(): string {
    return this.getLatest().__body;
  }

  setBody(body: string): void {
    this.getWritable().__body = body;
  }

  getProp(name: string): unknown {
    return parseAttrs(this.getLatest().__attrs)[name];
  }

  setProp(name: string, value: string): void {
    const writable = this.getWritable();
    writable.__attrs = setAttr(writable.__attrs, name, value);
  }

  isInline(): false {
    return false;
  }
}

export function $createMdxComponentNode(tag: string, attrs: string, body: string): MdxComponentNode {
  return new MdxComponentNode(tag, attrs, body);
}

export function $isMdxComponentNode(node: LexicalNode | null | undefined): node is MdxComponentNode {
  return node instanceof MdxComponentNode;
}

const ATTR_PATTERN = /([\w-]+)(?:=(?:"((?:[^"\\]|\\.)*)"|\{([^}]*)\}))?/g;

/** `cmd="a" exit={0} pending` -> { cmd: "a", exit: 0, pending: true }. `{expr}` values that aren't a number/boolean/null literal are kept as the raw expression text (no eval — see thread/components/RawBlock for the arbitrary-JSX boundary). */
export function parseAttrs(attrs: string): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const match of attrs.matchAll(ATTR_PATTERN)) {
    const [, key, quoted, expr] = match;
    if (!key) continue;
    if (quoted !== undefined) result[key] = quoted.replace(/\\"/g, '"');
    else if (expr !== undefined) result[key] = literalFromExpr(expr.trim());
    else result[key] = true;
  }
  return result;
}

/** Replaces (or appends) one `key="value"` pair in a raw attrs string, leaving every other attribute's formatting untouched. */
export function setAttr(attrs: string, key: string, value: string): string {
  const escaped = value.replace(/"/g, '\\"');
  const pattern = new RegExp(`(^|\\s)${key}=(?:"(?:[^"\\\\]|\\\\.)*"|\\{[^}]*\\})`);
  if (pattern.test(attrs)) return attrs.replace(pattern, (_match, lead) => `${lead}${key}="${escaped}"`);
  return ` ${key}="${escaped}"${attrs}`;
}

function literalFromExpr(expr: string): unknown {
  if (expr === "true") return true;
  if (expr === "false") return false;
  if (expr === "null") return null;
  if (/^-?\d+(\.\d+)?$/.test(expr)) return Number(expr);
  return expr;
}

/** `@lexical/markdown`'s default TRANSFORMERS has no horizontal-rule transformer, so this is the one custom element node the editor still needs. */
export class HorizontalRuleNode extends ElementNode {
  static getType(): string {
    return "horizontalrule";
  }

  static clone(node: HorizontalRuleNode): HorizontalRuleNode {
    return new HorizontalRuleNode(node.__key);
  }

  static importJSON(): HorizontalRuleNode {
    return $createHorizontalRuleNode();
  }

  exportJSON() {
    return { ...super.exportJSON(), type: HorizontalRuleNode.getType(), version: 1 };
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
