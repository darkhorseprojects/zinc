import { CodeHighlightNode, CodeNode } from "@lexical/code";
import { HorizontalRuleNode } from "@lexical/extension";
import { LinkNode } from "@lexical/link";
import { ListItemNode, ListNode } from "@lexical/list";
import { HeadingNode, QuoteNode } from "@lexical/rich-text";
import { TableCellNode, TableNode, TableRowNode } from "@lexical/table";
import { LineBreakNode } from "lexical";
import { EquationNode } from "./EquationNode";
import { ErrorNode } from "./ErrorNode";
import { ReasoningNode } from "./ReasoningNode";
import { RecallNode } from "./RecallNode";
import { ShellNode } from "./ShellNode";
import { TsxPreviewNode } from "./TsxPreviewNode";

export { $createEquationNode, $createEquationSourceNode, $isEquationNode, equationSource, parseEquationSource, EquationNode } from "./EquationNode";
export { $createErrorNode, $isErrorNode, ErrorNode } from "./ErrorNode";
export { $createReasoningNode, $isReasoningNode, ReasoningNode } from "./ReasoningNode";
export { $createRecallNode, $isRecallNode, RecallNode } from "./RecallNode";
export { $createShellNode, $isShellNode, ShellNode } from "./ShellNode";
export { $createTsxPreviewNode, $isTsxPreviewNode, TsxPreviewNode } from "./TsxPreviewNode";

export const zincLexicalNodes = [HeadingNode, QuoteNode, CodeNode, CodeHighlightNode, ListNode, ListItemNode, LinkNode, LineBreakNode, HorizontalRuleNode, TableNode, TableRowNode, TableCellNode, EquationNode, ReasoningNode, RecallNode, ShellNode, ErrorNode, TsxPreviewNode] as const;
