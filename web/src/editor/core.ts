import { $createCodeHighlightNode, $isCodeHighlightNode, CodeNode } from "@lexical/code-core";
import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import { ListItemNode, ListNode, registerList } from "@lexical/list";
import { registerRichText } from "@lexical/rich-text";
import { registerTableCellUnmergeTransform, registerTablePlugin, registerTableSelectionObserver, TableCellNode, TableNode, TableRowNode } from "@lexical/table";
import { mergeRegister } from "@lexical/utils";
import { $createLineBreakNode, $createTextNode, $isLineBreakNode, createEditor, type LexicalEditor, type LexicalNode } from "lexical";
import { SugarHigh } from "sugar-high";
import { highlight } from "./highlight";
import { zincLexicalNodes } from "./nodes";

export function createZincEditor(namespace: string, editable: boolean) {
  return createEditor({
    namespace,
    nodes: zincLexicalNodes,
    editable,
    theme: {
      code: "zinc-code", text: { code: "zinc-inline-code" }, table: "zinc-table", tableRow: "zinc-table-row", tableCell: "zinc-table-cell", tableCellHeader: "zinc-table-cell-header", tableCellSelected: "zinc-table-cell-selected", tableSelection: "zinc-table-selection",
      codeHighlight: { identifier: "sh__identifier", keyword: "sh__keyword", string: "sh__string", class: "sh__class", property: "sh__property", entity: "sh__entity", jsxliterals: "sh__jsxliterals", sign: "sh__sign", comment: "sh__comment", space: "sh__space" },
    },
    onError(error) { throw error; },
  });
}

export function registerCore(editor: LexicalEditor, editable: boolean) {
  const history = createEmptyHistoryState();
  const registrations = [registerRichText(editor), registerHistory(editor, history, 300), registerList(editor), registerTablePlugin(editor), registerCodeHighlight(editor)];
  if (editable) registrations.push(registerTableSelectionObserver(editor, true), registerTableCellUnmergeTransform(editor));
  return mergeRegister(...registrations);
}

function registerCodeHighlight(editor: LexicalEditor) {
  return editor.registerNodeTransform(CodeNode, (node) => {
    const next = highlighted(node.getTextContent(), node.getLanguage()), signature = next.map((child) => child.signature).join("\0");
    if (codeSignature(node.getChildren()) === signature) return;
    node.clear(); node.append(...next.map((child) => child.node));
  });
}
function highlighted(code: string, language?: string | null) {
  const children: Array<{ signature: string; node: ReturnType<typeof $createCodeHighlightNode> | ReturnType<typeof $createLineBreakNode> | ReturnType<typeof $createTextNode> }> = [], tokens = highlight(code, language);
  for (const [type, text] of tokens ?? [[-1, code] as [number, string]]) {
    const kind = tokens ? SugarHigh.TokenTypes[type] ?? "identifier" : null, parts = text.split("\n");
    for (let index = 0; index < parts.length; index++) { if (parts[index]) children.push(kind ? { signature: `${kind}:${parts[index]}`, node: $createCodeHighlightNode(parts[index], kind) } : { signature: `plain:${parts[index]}`, node: $createTextNode(parts[index]) }); if (index < parts.length - 1) children.push({ signature: "break:\n", node: $createLineBreakNode() }); }
  }
  return children;
}
function codeSignature(children: LexicalNode[]) { return children.map((child) => $isLineBreakNode(child) ? "break:\n" : $isCodeHighlightNode(child) ? `${child.getHighlightType() ?? "identifier"}:${child.getTextContent()}` : `plain:${child.getTextContent()}`).join("\0"); }
