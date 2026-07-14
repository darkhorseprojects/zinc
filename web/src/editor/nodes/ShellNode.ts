import { SugarHigh } from "sugar-high";
import { highlightShell } from "../highlight";
import { $applyNodeReplacement, DecoratorNode, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";

export type SerializedShellNode = Spread<{ command: string; output: string; type: "shell"; version: 1 }, SerializedLexicalNode>;

export class ShellNode extends DecoratorNode<null> {
  __command: string; __output: string;
  static getType() { return "shell"; }
  static clone(node: ShellNode) { return new ShellNode(node.__command, node.__output, node.__key); }
  static importJSON(value: SerializedShellNode) { return $createShellNode(value.command, value.output); }
  constructor(command: string, output: string, key?: NodeKey) { super(key); this.__command = command; this.__output = output; }
  exportJSON(): SerializedShellNode { return { command: this.__command, output: this.__output, type: "shell", version: 1 }; }
  createDOM(_config: EditorConfig) { const card = document.createElement("section"); card.className = "zinc-shell"; render(card, this.__command, this.__output); return card; }
  updateDOM(previous: ShellNode, element: HTMLElement) { if (previous.__command !== this.__command || previous.__output !== this.__output) render(element, this.__command, this.__output); return false; }
  decorate(): null { return null; }
  isInline(): false { return false; }
}
function render(card: HTMLElement, command: string, output: string) {
  card.replaceChildren(); const cap = document.createElement("div"), prompt = document.createElement("span"), body = document.createElement("pre");
  cap.className = "zinc-shell-command"; prompt.className = "sh__sign"; prompt.textContent = "$ "; cap.append(prompt);
  for (const [type, text] of highlightShell(command)) { const span = document.createElement("span"); span.className = `sh__${SugarHigh.TokenTypes[type] ?? "identifier"}`; span.textContent = text; cap.append(span); }
  body.className = "zinc-shell-output"; body.textContent = output; card.append(cap, body);
}
export function $createShellNode(command = "", output = "") { return $applyNodeReplacement(new ShellNode(command, output)); }
export function $isShellNode(node: LexicalNode | null | undefined): node is ShellNode { return node instanceof ShellNode; }
