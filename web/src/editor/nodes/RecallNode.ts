import { $applyNodeReplacement, DecoratorNode, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";
export type SerializedRecallNode = Spread<{ packet: string; from?: number; to?: number; content: string; type: "recall"; version: 1 }, SerializedLexicalNode>;
export class RecallNode extends DecoratorNode<null> {
  __packet: string; __from?: number; __to?: number; __content: string;
  static getType() { return "recall"; }
  static clone(node: RecallNode) { return new RecallNode(node.__packet, node.__content, node.__from, node.__to, node.__key); }
  static importJSON(value: SerializedRecallNode) { return $createRecallNode(value.packet, value.content, value.from, value.to); }
  constructor(packet: string, content: string, from?: number, to?: number, key?: NodeKey) { super(key); this.__packet = packet; this.__content = content; this.__from = from; this.__to = to; }
  exportJSON(): SerializedRecallNode { return { packet: this.__packet, content: this.__content, ...(this.__from === undefined ? {} : { from: this.__from }), ...(this.__to === undefined ? {} : { to: this.__to }), type: "recall", version: 1 }; }
  createDOM(_config: EditorConfig) { const card = document.createElement("section"); card.className = "zinc-recall"; render(card, this); return card; }
  updateDOM(previous: RecallNode, card: HTMLElement) { if (JSON.stringify(previous.exportJSON()) !== JSON.stringify(this.exportJSON())) render(card, this); return false; }
  decorate(): null { return null; }
  isInline(): false { return false; }
}
function render(card: HTMLElement, node: RecallNode) { card.replaceChildren(); const meta = document.createElement("div"), body = document.createElement("pre"); meta.className = "zinc-recall-meta"; meta.textContent = `${node.__packet} · ${node.__from === undefined && node.__to === undefined ? "full" : `[${node.__from ?? 0}, ${node.__to ?? "end"})`}`; body.className = "zinc-recall-content"; body.textContent = node.__content; card.append(meta, body); }
export function $createRecallNode(packet: string, content: string, from?: number, to?: number) { return $applyNodeReplacement(new RecallNode(packet, content, from, to)); }
export function $isRecallNode(node: LexicalNode | null | undefined): node is RecallNode { return node instanceof RecallNode; }
