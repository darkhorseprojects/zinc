import { $createHorizontalRuleNode, $isHorizontalRuleNode, HorizontalRuleNode } from "@lexical/extension";
import { $convertFromMarkdownString, $convertToMarkdownString, isTableRowDivider, TRANSFORMERS, type ElementTransformer, type MultilineElementTransformer, type TextMatchTransformer, type Transformer } from "@lexical/markdown";
import { $createTableCellNode, $createTableNode, $createTableRowNode, $isTableCellNode, $isTableNode, $isTableRowNode, TableCellHeaderStates, TableCellNode, TableNode, TableRowNode } from "@lexical/table";
import { $createParagraphNode, $isParagraphNode, $isTextNode, createEditor, type LexicalEditor } from "lexical";
import { markdownBlocks } from "../../src/markdown-blocks";
import { $createEquationNode, $isEquationNode, EquationNode, zincLexicalNodes } from "./editor/nodes";

type SerializedNode = Record<string, unknown>;

const HORIZONTAL_RULE_TRANSFORMER: Transformer = {
  dependencies: [HorizontalRuleNode],
  export: (node) => $isHorizontalRuleNode(node) ? "---" : null,
  regExp: /^(?:---|___|\*\*\*)\s*$/,
  replace: (parent) => { parent.replace($createHorizontalRuleNode()); },
  triggerOnEnter: true,
  type: "element",
};

const TABLE_ROW = /^(?:\|)(.+)(?:\|)\s?$/;
const TABLE_TRANSFORMER: ElementTransformer = {
  dependencies: [TableNode, TableRowNode, TableCellNode],
  export: (node) => {
    if (!$isTableNode(node)) return null;
    const output: string[] = [];
    for (const row of node.getChildren()) {
      if (!$isTableRowNode(row)) continue;
      const cells: string[] = [];
      let header = false;
      for (const cell of row.getChildren()) if ($isTableCellNode(cell)) {
        cells.push($convertToMarkdownString(ZINC_MARKDOWN_TRANSFORMERS, cell).replace(/\n/g, "\\n").trim());
        header ||= cell.getHeaderStyles() === TableCellHeaderStates.ROW;
      }
      output.push(`| ${cells.join(" | ")} |`);
      if (header) output.push(`| ${cells.map(() => "---").join(" | ")} |`);
    }
    return output.join("\n");
  },
  regExp: TABLE_ROW,
  replace: (parent, _children, match) => {
    if (isTableRowDivider(match[0])) {
      const table = parent.getPreviousSibling(), row = $isTableNode(table) ? table.getLastChild() : null;
      if ($isTableRowNode(row)) row.getChildren().forEach((cell) => { if ($isTableCellNode(cell)) cell.setHeaderStyles(TableCellHeaderStates.ROW, TableCellHeaderStates.ROW); });
      if ($isTableRowNode(row)) parent.remove();
      return;
    }
    const first = tableCells(match[0]);
    if (!first) return;
    const rows = [first];
    let sibling = parent.getPreviousSibling(), columns = first.length;
    while ($isParagraphNode(sibling) && sibling.getChildrenSize() === 1 && $isTextNode(sibling.getFirstChild())) {
      const cells = tableCells(sibling.getTextContent());
      if (!cells) break;
      rows.unshift(cells); columns = Math.max(columns, cells.length);
      const previous = sibling.getPreviousSibling(); sibling.remove(); sibling = previous;
    }
    const table = $createTableNode();
    for (const cells of rows) {
      const row = $createTableRowNode(); table.append(row);
      for (let index = 0; index < columns; index++) row.append(cells[index] ?? tableCell(""));
    }
    const previous = parent.getPreviousSibling();
    if ($isTableNode(previous) && tableColumns(previous) === columns) { previous.append(...table.getChildren()); parent.remove(); }
    else parent.replace(table);
    table.selectEnd();
  },
  type: "element",
};

const BLOCK_EQUATION: MultilineElementTransformer = {
  dependencies: [EquationNode],
  export: (node) => {
    if (!$isParagraphNode(node) || node.getChildrenSize() !== 1) return null;
    const equation = node.getFirstChild();
    return $isEquationNode(equation) && equation.isDisplay() ? `$$\n${equation.getEquation()}\n$$` : null;
  },
  regExpStart: /^\$\$\s*$/,
  regExpEnd: /^\$\$\s*$/,
  replace: (root, _children, _start, _end, lines) => {
    const equation = [...lines ?? []];
    if (equation[0] === "") equation.shift();
    if (equation.at(-1) === "") equation.pop();
    root.append($createParagraphNode().append($createEquationNode(equation.join("\n"), true)));
  },
  type: "multiline-element",
};

const SINGLE_LINE_BLOCK_EQUATION: ElementTransformer = {
  dependencies: [EquationNode],
  export: () => null,
  regExp: /^\$\$(.+)\$\$\s*$/,
  replace: (parent, _children, match) => { parent.clear().append($createEquationNode(match[1], true)); },
  type: "element",
};

const INLINE_EQUATION: TextMatchTransformer = {
  dependencies: [EquationNode],
  export: (node) => $isEquationNode(node) && !node.isDisplay() ? `$${escapeEquation(node.getEquation())}$` : null,
  importRegExp: /(?<!\$)\$((?:\\.|[^$\\\n])+?)\$(?!\$)/,
  regExp: /(?:^|[^$])\$((?:\\.|[^$\\\n])+?)\$$/,
  replace: (textNode, match) => {
    const prefix = match[0][0] === "$" ? "" : match[0][0];
    const equation = $createEquationNode(unescapeEquation(match[1]));
    if (!prefix) textNode.replace(equation);
    else { textNode.setTextContent(prefix); textNode.insertAfter(equation); }
  },
  trigger: "$",
  type: "text-match",
};

export const ZINC_MARKDOWN_TRANSFORMERS: Transformer[] = [TABLE_TRANSFORMER, BLOCK_EQUATION, SINGLE_LINE_BLOCK_EQUATION, INLINE_EQUATION, ...TRANSFORMERS, HORIZONTAL_RULE_TRANSFORMER];

export function markdownToNodes(markdown: string): SerializedNode[] {
  if (!markdown.trim()) return [];
  const display = markdown.match(/^\$\$\n?([\s\S]*?)\n?\$\$$/);
  if (display) return [element("paragraph", [{ source: markdown, type: "equation", version: 1 }], { textFormat: 0, textStyle: "" })];
  return blockTokens(markdownBlocks(markdown)).map(importProducts);
}

export function nodesToMarkdown(nodes: SerializedNode[]): string {
  return nodes.length ? sourceBlocks(nodes) : "";
}

function lexicalMarkdown(nodes: SerializedNode[]) {
  const exportEditor = markdownEditor("zinc-markdown-export");
  exportEditor.setEditorState(exportEditor.parseEditorState(documentFromNodes(nodes.map(productNodeToFenceCode)) as never));
  let markdown = "";
  exportEditor.getEditorState().read(() => { markdown = $convertToMarkdownString(ZINC_MARKDOWN_TRANSFORMERS); });
  return markdown;
}

function blockTokens(tokens: any[], listDepth = 0): SerializedNode[] {
  return tokens.flatMap((token): SerializedNode[] => {
    if (!token || token.type === "space") return [];
    if (token.type === "paragraph") return [element("paragraph", inlineTokens(token.tokens ?? [{ type: "text", text: token.text }]), { textFormat: 0, textStyle: "" })];
    if (token.type === "heading") return [element("heading", [markerNode(`${"#".repeat(token.depth)} `, "block"), ...inlineTokens(token.tokens ?? [])], { tag: `h${token.depth}` })];
    if (token.type === "blockquote") return [element("quote", blockTokens(token.tokens ?? []).map((node) => prependMarker(node, "> ")))];
    if (token.type === "hr") return [{ type: "horizontalrule", version: 1 }];
    if (token.type === "code") return [element("code", textChildren(token.text ?? ""), { language: token.lang ?? null })];
    if (token.type === "list") return [listNode(token, listDepth)];
    if (token.type === "table") {
      const rows = [token.header ?? [], ...(token.rows ?? [])];
      return [element("table", rows.map((row: any[], rowIndex: number) => element("tablerow", row.map((cell: any, cellIndex: number) => element("tablecell", [element("paragraph", [markerNode(cellIndex === 0 ? "| " : " ", "table"), ...inlineTokens(cell.tokens ?? [{ type: "text", text: cell.text ?? "" }]), markerNode(" |", "table")], { textFormat: 0, textStyle: "" })], { backgroundColor: null, colSpan: 1, headerState: rowIndex === 0 ? 1 : 0, rowSpan: 1 })))))];
    }
    if (token.type === "blockKatex") return [element("paragraph", [{ source: `$$\n${token.text ?? token.raw ?? ""}\n$$`, type: "equation", version: 1 }], { textFormat: 0, textStyle: "" })];
    if (token.type === "html" || token.type === "text") return [element("paragraph", inlineTokens(token.tokens ?? [{ type: "text", text: token.text ?? token.raw ?? "" }]), { textFormat: 0, textStyle: "" })];
    return [];
  });
}
function listNode(token: any, depth: number) {
  const items: SerializedNode[] = [];
  for (const [itemIndex, item] of (token.items ?? []).entries()) {
    const tokens = item.tokens ?? [], nested = tokens.filter((child: any) => child?.type === "list");
    const prefix = item.task ? `- [${item.checked ? "x" : " "}] ` : token.ordered ? `${(typeof token.start === "number" ? token.start : 1) + itemIndex}. ` : "- ";
    items.push(element("listitem", [markerNode(prefix, "block"), ...listItemChildren(tokens.filter((child: any) => child?.type !== "list"), depth)], { checked: item.task ? Boolean(item.checked) : undefined, indent: depth, value: items.length + 1 }));
    for (const child of nested) items.push(element("listitem", [listNode(child, depth + 1)], { indent: depth, value: items.length + 1 }));
  }
  return element("list", items, { listType: token.ordered ? "number" : "bullet", start: typeof token.start === "number" ? token.start : 1, tag: token.ordered ? "ol" : "ul" });
}
function listItemChildren(tokens: any[], depth: number) {
  const blocks = blockTokens(tokens, depth);
  return blocks.flatMap((node) => node.type === "paragraph" && Array.isArray(node.children) ? node.children as SerializedNode[] : [node]);
}
function inlineTokens(tokens: any[], format = 0): SerializedNode[] {
  return tokens.flatMap((token): SerializedNode[] => {
    if (!token) return [];
    if (token.type === "text") return token.tokens ? inlineTokens(token.tokens, format) : inlineText(token.text ?? token.raw ?? "", format);
    if (token.type === "escape") return [markerNode("\\", "escape"), ...textNode(token.text ?? "", format)];
    if (token.type === "strong") return [markerNode("**", "inline"), ...inlineTokens(token.tokens ?? [], format | 1), markerNode("**", "inline")];
    if (token.type === "em") return [markerNode("*", "inline"), ...inlineTokens(token.tokens ?? [], format | 2), markerNode("*", "inline")];
    if (token.type === "del") return [markerNode("~~", "inline"), ...inlineTokens(token.tokens ?? [], format | 4), markerNode("~~", "inline")];
    if (token.type === "codespan") return [markerNode("`", "inline"), ...textNode(token.text ?? "", format | 16), markerNode("`", "inline")];
    if (token.type === "br") return [{ type: "linebreak", version: 1 }];
    if (token.type === "link") return [element("link", [markerNode("[", "link"), ...inlineTokens(token.tokens ?? [], format), markerNode("](", "link"), markerNode(token.href ?? "", "link-target"), markerNode(")", "link")], { rel: null, target: null, title: token.title ?? null, url: token.href ?? "" })];
    return inlineText(token.text ?? token.raw ?? "", format);
  });
}
function textNode(value: string, format: number): SerializedNode[] { return value ? [{ detail: 0, format, mode: "normal", style: "", text: value, type: "text", version: 1 }] : []; }
function inlineText(value: string, format: number): SerializedNode[] {
  const result: SerializedNode[] = []; let cursor = 0;
  for (const match of value.matchAll(/(?<!\\)\$((?:\\.|[^$\\\n])+?)\$(?!\$)/g)) {
    const index = match.index ?? 0; result.push(...textNode(value.slice(cursor, index), format)); result.push({ source: match[0], type: "equation", version: 1 }); cursor = index + match[0].length;
  }
  result.push(...textNode(value.slice(cursor), format)); return result;
}
function markerNode(text: string, _kind: string): SerializedNode { return { detail: 2, format: 0, mode: "normal", style: "", text, type: "text", version: 1 }; }
function prependMarker(node: SerializedNode, text: string): SerializedNode {
  if (Array.isArray(node.children)) return { ...node, children: [markerNode(text, "block"), ...node.children.filter(record)] };
  return node;
}

function sourceBlocks(nodes: SerializedNode[]) { return nodes.every(inlineRoot) ? nodes.map(inlineSource).join("") : nodes.map(sourceBlock).filter(Boolean).join("\n\n"); }
function inlineRoot(node: SerializedNode) { return ["text", "linebreak", "equation", "link"].includes(String(node.type)); }
function sourceBlock(node: SerializedNode): string {
  if (node.type === "list") return listSource(node, 0);
  if (node.type === "table") {
    const rows = nodeChildren(node).map((row) => nodeChildren(row).map((cell) => inlineSource(cell)).join(""));
    if (rows.length) rows.splice(1, 0, `| ${nodeChildren(nodeChildren(node)[0]).map(() => "---").join(" | ")} |`);
    return rows.join("\n");
  }
  if (node.type === "quote") return nodeChildren(node).map(sourceBlock).join("\n");
  if (["paragraph", "heading", "listitem", "link"].includes(String(node.type))) return inlineSource(node);
  return lexicalMarkdown([node]);
}
function listSource(node: SerializedNode, depth: number): string {
  const lines: string[] = [];
  for (const item of nodeChildren(node)) {
    const children = nodeChildren(item), nested = children.filter((child) => child.type === "list"), own = children.filter((child) => child.type !== "list");
    if (own.length) lines.push(`${"    ".repeat(depth)}${own.map(inlineSource).join("")}`);
    for (const child of nested) lines.push(listSource(child, depth + 1));
  }
  return lines.join("\n");
}
function inlineSource(node: SerializedNode): string { if (typeof node.text === "string") return node.text; if (node.type === "linebreak") return "\n"; if (node.type === "equation" && typeof node.source === "string") return node.source; return nodeChildren(node).map(inlineSource).join(""); }
function nodeChildren(node: SerializedNode) { return Array.isArray(node.children) ? node.children.filter(record) as SerializedNode[] : []; }

function escapeEquation(equation: string) { return equation.replace(/([\\$])/g, "\\$1"); }
function unescapeEquation(equation: string) { return equation.replace(/\\([\\$])/g, "$1"); }

function tableColumns(table: TableNode) { const row = table.getFirstChild(); return $isTableRowNode(row) ? row.getChildrenSize() : 0; }
function tableCell(markdown: string) {
  const cell = $createTableCellNode(TableCellHeaderStates.NO_STATUS);
  $convertFromMarkdownString(markdown.replace(/\\n/g, "\n"), ZINC_MARKDOWN_TRANSFORMERS, cell);
  return cell;
}
function tableCells(markdown: string) { const match = markdown.match(TABLE_ROW); return match?.[1] ? match[1].split("|").map(tableCell) : null; }

function documentFromNodes(nodes: SerializedNode[]) { return { root: { children: nodes, direction: null, format: "", indent: 0, type: "root", version: 1 } }; }

function markdownEditor(namespace: string): LexicalEditor {
  return createEditor({ namespace, nodes: zincLexicalNodes, onError: (error) => { throw error; } });
}

function editorNodes(editor: LexicalEditor): SerializedNode[] {
  const state = editor.getEditorState().toJSON() as unknown as { root?: { children?: unknown[] } };
  return (Array.isArray(state.root?.children) ? state.root.children : []).filter(record) as SerializedNode[];
}

function importProducts(node: SerializedNode): SerializedNode {
  const nested = Array.isArray(node.children) ? { ...node, children: node.children.filter(record).map(importProducts) } : node;
  return productFenceCodeToNode(nested);
}

function productFenceCodeToNode(node: SerializedNode): SerializedNode {
  if (node.type !== "code" || typeof node.language !== "string") return node;
  if (node.language === "tsx") return { source: nodeText(node), type: "tsx-preview", version: 1 };
  return ["reasoning", "error"].includes(node.language) ? element(node.language, textChildren(nodeText(node))) : node;
}

function productNodeToFenceCode(node: SerializedNode): SerializedNode {
  if (node.type === "tsx-preview") return element("code", textChildren(typeof node.source === "string" ? node.source : ""), { language: "tsx" });
  return ["reasoning", "error"].includes(String(node.type)) ? element("code", textChildren(nodeText(node)), { language: node.type }) : node;
}

function element(type: unknown, children: SerializedNode[], extra: Record<string, unknown> = {}): SerializedNode { return { children, direction: null, format: "", indent: 0, type, version: 1, ...extra }; }
function textChildren(value: string) { return value.split("\n").flatMap((part, index, all) => [...(part ? [{ detail: 0, format: 0, mode: "normal", style: "", text: part, type: "text", version: 1 }] : []), ...(index < all.length - 1 ? [{ type: "linebreak", version: 1 }] : [])]); }
function nodeText(node: unknown): string { if (!record(node)) return ""; if (typeof node.text === "string") return node.text; if (node.type === "linebreak") return "\n"; return (Array.isArray(node.children) ? node.children : []).map(nodeText).join(""); }
function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
