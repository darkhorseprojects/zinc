import katex from "katex";
import { $applyNodeReplacement, DecoratorNode, type DOMExportOutput, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";

export type SerializedEquationNode = Spread<{ source: string; type: "equation"; version: 1 }, SerializedLexicalNode>;

export class EquationNode extends DecoratorNode<null> {
  __source: string;
  static getType(): string { return "equation"; }
  static clone(node: EquationNode) { return new EquationNode(node.__source, node.__key); }
  static importJSON(value: SerializedEquationNode) { return $createEquationSourceNode(value.source); }
  constructor(source: string, key?: NodeKey) { super(key); this.__source = source; }
  exportJSON(): SerializedEquationNode { return { source: this.__source, type: "equation", version: 1 }; }
  exportDOM(): DOMExportOutput { const element = document.createElement("span"); element.textContent = this.getEquation(); element.setAttribute("role", "math"); return { element }; }
  createDOM(_config: EditorConfig) { const element = document.createElement("span"); element.className = "zinc-equation"; element.dataset.lexicalKey = this.getKey(); render(element, this.__source); return element; }
  updateDOM(previous: EquationNode, element: HTMLElement) { if (previous.__source !== this.__source) render(element, this.__source); return false; }
  decorate(): null { return null; }
  isInline(): true { return true; }
  isIsolated(): true { return true; }
  getSource() { return this.getLatest().__source; }
  setSource(source: string) { this.getWritable().__source = source; return this; }
  getEquation() { return parseEquationSource(this.getLatest().__source)?.equation ?? this.getLatest().__source; }
  isDisplay() { return parseEquationSource(this.getLatest().__source)?.display ?? false; }
}

function render(element: HTMLElement, source: string) {
  const parsed = parseEquationSource(source); element.replaceChildren(); element.toggleAttribute("data-display", parsed?.display === true); element.setAttribute("aria-label", parsed?.equation ?? source);
  if (!parsed) { element.textContent = source; return; }
  katex.render(parsed.equation, element, { displayMode: parsed.display, throwOnError: false, trust: false, strict: "ignore" });
}

export function equationSource(equation: string, display = false) { return display ? `$$\n${equation}\n$$` : `$${equation}$`; }
export function parseEquationSource(source: string) {
  if (source.startsWith("$$") && source.endsWith("$$") && source.length >= 4) return { display: true, equation: source.slice(2, -2).replace(/^\n|\n$/g, "") };
  if (source.startsWith("$") && source.endsWith("$") && source.length >= 2 && !source.startsWith("$$")) return { display: false, equation: source.slice(1, -1) };
  return null;
}
export function $createEquationNode(equation: string, display = false) { return $applyNodeReplacement(new EquationNode(equationSource(equation, display))); }
export function $createEquationSourceNode(source: string) { return $applyNodeReplacement(new EquationNode(source)); }
export function $isEquationNode(node: LexicalNode | null | undefined): node is EquationNode { return node instanceof EquationNode; }
