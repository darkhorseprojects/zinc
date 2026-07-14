import { markdownToNodes, nodesToMarkdown } from "../markdown";

export type SerializedNode = Record<string, unknown>;
export type SerializedDocument = { root: { children: SerializedNode[]; direction: null; format: string; indent: number; type: "root"; version: 1 } };
export type BlockFormat = "markdown" | "reasoning" | "error" | "tsx" | "shell" | "recall" | "code";
export type DecodedBlock = { format: BlockFormat; document: SerializedDocument; editable: boolean };

const encoder = new TextEncoder(), decoder = new TextDecoder("utf-8", { fatal: true });

export function decodeBlock(bytes: Uint8Array): DecodedBlock {
  const value = JSON.parse(decoder.decode(bytes));
  if (!record(value) || typeof value.zinc !== "string") throw new Error("Invalid Zinc block packet");
  if (value.zinc === "text" && typeof value.format === "string" && typeof value.text === "string") {
    if (value.format === "markdown") return block("markdown", markdownToNodes(value.text), true);
    if (value.format === "reasoning") return block("reasoning", [element("reasoning", markdownToNodes(value.text))], true);
    if (value.format === "error") return block("error", [element("error", textChildren(value.text))], true);
    if (value.format === "tsx") return block("tsx", [{ source: value.text, type: "tsx-preview", version: 1 }], true);
    return block("code", [element("code", textChildren(value.text), { language: value.format })], true);
  }
  if (value.zinc === "shell" && typeof value.command === "string" && typeof value.output === "string") return block("shell", [{ command: value.command, output: value.output, type: "shell", version: 1 }], false);
  if (value.zinc === "recall" && typeof value.packet === "string" && typeof value.content === "string") return block("recall", [{ packet: value.packet, content: value.content, ...(Number.isInteger(value.from) ? { from: value.from } : {}), ...(Number.isInteger(value.to) ? { to: value.to } : {}), type: "recall", version: 1 }], false);
  if (value.zinc === "definition" && typeof value.document === "string") return block("code", [element("code", textChildren(value.document), { language: "circuitry" })], true);
  throw new Error("Unsupported Zinc block packet");
}

export function encodeBlock(format: BlockFormat, document: SerializedDocument) {
  const nodes = documentNodes(document);
  if (format === "markdown") return textPacket("markdown", nodesToMarkdown(nodes));
  if (format === "reasoning") { const node = nodes.find((value) => value.type === "reasoning"); return textPacket("reasoning", nodesToMarkdown(nodeChildren(node))); }
  if (format === "error") return textPacket("error", nodeText(nodes.find((value) => value.type === "error")));
  if (format === "tsx") {
    const node = nodes[0], source = node?.type === "tsx-preview" && typeof node.source === "string" ? node.source : nodeText(node);
    return textPacket("tsx", source);
  }
  if (format === "code") { const node = nodes[0]; return textPacket(typeof node?.language === "string" ? node.language : "text", nodeText(node)); }
  throw new Error(`${format} blocks are read-only`);
}

export function markdownPacket(markdown: string) { return textPacket("markdown", markdown); }
export function textPacket(format: string, text: string) { return encoder.encode(`${JSON.stringify({ zinc: "text", format, text })}\n`); }
export function documentFromNodes(nodes: SerializedNode[]): SerializedDocument { return { root: { children: nodes.length ? nodes : [element("paragraph", [], { textFormat: 0, textStyle: "" })], direction: null, format: "", indent: 0, type: "root", version: 1 } }; }
export function documentNodes(document: SerializedDocument | Record<string, unknown>): SerializedNode[] { const root = record(document.root) ? document.root : {}; return Array.isArray(root.children) ? root.children.filter(record) : []; }
export function nodeText(node: unknown): string { if (!record(node)) return ""; if (typeof node.text === "string") return node.text; if (node.type === "linebreak") return "\n"; if ((node.type === "equation" || node.type === "tsx-preview") && typeof node.source === "string") return node.source; return (Array.isArray(node.children) ? node.children : []).map(nodeText).join(""); }

function block(format: BlockFormat, nodes: SerializedNode[], editable: boolean): DecodedBlock { return { format, document: documentFromNodes(nodes), editable }; }
function nodeChildren(node: unknown) { return record(node) && Array.isArray(node.children) ? node.children.filter(record) : []; }
function element(type: string, children: SerializedNode[], extra: Record<string, unknown> = {}): SerializedNode { return { children, direction: null, format: "", indent: 0, type, version: 1, ...extra }; }
function textChildren(value: string): SerializedNode[] { return value.split("\n").flatMap((part, index, all) => [...(part ? [{ detail: 0, format: 0, mode: "normal", style: "", text: part, type: "text", version: 1 }] : []), ...(index < all.length - 1 ? [{ type: "linebreak", version: 1 }] : [])]); }
function record(value: unknown): value is Record<string, any> { return typeof value === "object" && value !== null && !Array.isArray(value); }
