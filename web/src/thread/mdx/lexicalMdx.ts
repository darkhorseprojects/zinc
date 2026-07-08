import { $createCodeNode, $isCodeNode, CodeNode } from "@lexical/code";
import {
  $createHeadingNode,
  $isHeadingNode,
  HeadingNode,
  QuoteNode,
  $createQuoteNode,
  $isQuoteNode,
  type HeadingTagType,
} from "@lexical/rich-text";
import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $isParagraphNode,
  $isTextNode,
  TextNode,
  LineBreakNode,
  $createLineBreakNode,
  $isLineBreakNode,
  IS_BOLD,
  IS_ITALIC,
  IS_STRIKETHROUGH,
  IS_CODE,
  type ElementNode,
  type LexicalEditor,
  type LexicalNode,
} from "lexical";
import {
  ListNode,
  ListItemNode,
  $createListNode,
  $createListItemNode,
  $isListNode,
  $isListItemNode,
} from "@lexical/list";
import { LinkNode, $createLinkNode, $isLinkNode } from "@lexical/link";
import {
  $createMdxSourceNode,
  $createReasoningNode,
  $createCommandNode,
  $createErrorNode,
  $createSourceNode,
  $isMdxSourceNode,
  $isReasoningNode,
  $isCommandNode,
  $isErrorNode,
  $isSourceNode,
  MdxSourceNode,
  ReasoningNode,
  CommandNode,
  ErrorNode,
  SourceNode,
  HorizontalRuleNode,
  $createHorizontalRuleNode,
  $isHorizontalRuleNode,
  type ComponentStatus,
} from "~/thread/nodes";
import { parseMdx, sourceForNode, type MdastNode, type MdastRoot } from "./parseMdx";
import { serializeMdastChildren, serializeMdastNode, serializeMdx } from "./serializeMdx";

export const zincLexicalNodes = [
  HeadingNode,
  QuoteNode,
  CodeNode,
  MdxSourceNode,
  ReasoningNode,
  CommandNode,
  ErrorNode,
  SourceNode,
  ListNode,
  ListItemNode,
  LinkNode,
  HorizontalRuleNode,
  LineBreakNode,
] as const;

export function importMdxToLexical(editor: LexicalEditor, source: string): void {
  const parsed = parseMdx(source);
  editor.update(() => {
    const root = $getRoot();
    root.clear();

    if (!parsed.ok) {
      root.append($createMdxSourceNode(source));
      return;
    }

    for (const child of parsed.root.children) root.append(mdastNodeToLexical(child, source));
  }, { discrete: true });
}

export function exportLexicalToMdx(editor: LexicalEditor): string {
  let source = "";
  editor.getEditorState().read(() => {
    source = $getRoot()
      .getChildren()
      .map(lexicalNodeToSource)
      .filter((block): block is string => Boolean(block?.trim()))
      .join("\n\n");
  });
  return source;
}

function lexicalNodeToSource(node: LexicalNode): string | null {
  if ($isMdxSourceNode(node)) return node.getSource().trimEnd();
  if ($isReasoningNode(node)) return `<Reasoning>\n${node.getText().trimEnd()}\n</Reasoning>`;
  if ($isCommandNode(node)) return commandToMdx(node);
  if ($isErrorNode(node)) return errorToMdx(node);
  if ($isSourceNode(node)) return sourceToMdx(node);
  const children = lexicalNodeToMdast(node);
  if (!children.length) return null;
  return serializeMdx({ type: "root", children });
}

function mdastNodeToLexical(node: MdastNode, source: string): LexicalNode {
  switch (node.type) {
    case "paragraph":
      return appendInlineNodes($createParagraphNode(), node.children);
    case "heading":
      return appendInlineNodes($createHeadingNode(headingTag(node.depth)), node.children);
    case "blockquote":
      return appendInlineNodes($createQuoteNode(), node.children);
    case "list":
      return appendListNodes(node, source);
    case "listItem":
      return appendInlineNodes($createListItemNode(), node.children);
    case "thematicBreak":
      return $createHorizontalRuleNode();
    case "code":
      return appendText($createCodeNode(node.lang ?? undefined), node.value ?? "");
    case "mdxJsxFlowElement":
      return mdxComponentToLexical(node, source);
    default:
      return $createMdxSourceNode(sourceForNode(source, node) ?? serializeMdastNode(node));
  }
}

function appendListNodes(node: MdastNode, source: string): LexicalNode {
  const listType = node.ordered ? "number" : "bullet";
  const listNode = $createListNode(listType);
  if (node.children) {
    for (const child of node.children) {
      if (child.type === "listItem") {
        listNode.append(mdastNodeToLexical(child, source));
      }
    }
  }
  return listNode;
}

function appendInlineNodes<T extends ElementNode>(elementNode: T, children: MdastNode[] | undefined, activeFormats: number = 0): T {
  if (!children) return elementNode;

  for (const child of children) {
    switch (child.type) {
      case "text": {
        const textNode = $createTextNode(child.value ?? "");
        if (activeFormats > 0) {
          textNode.setFormat(activeFormats);
        }
        elementNode.append(textNode);
        break;
      }
      case "strong": {
        appendInlineNodes(elementNode, child.children, activeFormats | IS_BOLD);
        break;
      }
      case "emphasis": {
        appendInlineNodes(elementNode, child.children, activeFormats | IS_ITALIC);
        break;
      }
      case "delete": {
        appendInlineNodes(elementNode, child.children, activeFormats | IS_STRIKETHROUGH);
        break;
      }
      case "inlineCode": {
        const textNode = $createTextNode(child.value ?? "");
        textNode.setFormat(activeFormats | IS_CODE);
        elementNode.append(textNode);
        break;
      }
      case "link": {
        const linkUrl = String(child.url ?? "");
        const linkNode = $createLinkNode(linkUrl);
        appendInlineNodes(linkNode, child.children, activeFormats);
        elementNode.append(linkNode);
        break;
      }
      case "break": {
        elementNode.append($createLineBreakNode());
        break;
      }
      default: {
        const value = child.value ?? serializeMdastNode(child);
        const textNode = $createTextNode(value);
        if (activeFormats > 0) {
          textNode.setFormat(activeFormats);
        }
        elementNode.append(textNode);
        break;
      }
    }
  }

  return elementNode;
}

function lexicalNodeToMdast(node: LexicalNode): MdastNode[] {
  if ($isParagraphNode(node)) {
    const children = lexicalChildrenToMdast(node);
    return children.length ? [{ type: "paragraph", children }] : [];
  }

  if ($isHeadingNode(node)) {
    const depth = Number(node.getTag().slice(1));
    const children = lexicalChildrenToMdast(node);
    return [{ type: "heading", depth, children }];
  }

  if ($isQuoteNode(node)) {
    const children = lexicalChildrenToMdast(node);
    return [{ type: "blockquote", children }];
  }

  if ($isListNode(node)) {
    const ordered = node.getListType() === "number";
    const children = node.getChildren().flatMap(lexicalNodeToMdast);
    return [{ type: "list", ordered, children }];
  }

  if ($isListItemNode(node)) {
    const children = lexicalChildrenToMdast(node);
    return [{ type: "listItem", children }];
  }

  if ($isHorizontalRuleNode(node)) {
    return [{ type: "thematicBreak" }];
  }

  if ($isCodeNode(node)) {
    return [{ type: "code", lang: node.getLanguage() ?? undefined, value: node.getTextContent() }];
  }

  if ($isMdxSourceNode(node)) {
    return [{ type: "mdxSource", value: node.getSource() }];
  }

  return [];
}

function lexicalChildrenToMdast(elementNode: ElementNode): MdastNode[] {
  const children: MdastNode[] = [];
  for (const child of elementNode.getChildren()) {
    if ($isTextNode(child)) {
      children.push(...textNodeToMdast(child));
    } else if ($isLinkNode(child)) {
      const linkChildren = lexicalChildrenToMdast(child);
      children.push({ type: "link", url: child.getURL(), children: linkChildren });
    } else if ($isLineBreakNode(child)) {
      children.push({ type: "break" });
    } else {
      children.push(...lexicalNodeToMdast(child));
    }
  }
  return children;
}

function textNodeToMdast(textNode: TextNode): MdastNode[] {
  const value = textNode.getTextContent();
  if (!value) return [];

  let node: MdastNode = { type: "text", value };
  const format = textNode.getFormat();

  if (format & IS_CODE) {
    node = { type: "inlineCode", value };
  }
  if (format & IS_STRIKETHROUGH) {
    node = { type: "delete", children: [node] };
  }
  if (format & IS_ITALIC) {
    node = { type: "emphasis", children: [node] };
  }
  if (format & IS_BOLD) {
    node = { type: "strong", children: [node] };
  }

  return [node];
}

function mdxComponentToLexical(node: MdastNode, source: string): LexicalNode {
  if (node.name === "Reasoning") return $createReasoningNode(serializeMdastChildren(node).trim());
  if (node.name === "Command") {
    return $createCommandNode({
      cmd: stringAttribute(node, "cmd"),
      exit: nullableNumberAttribute(node, "exit"),
      status: statusAttribute(node, "status"),
      label: stringAttribute(node, "label"),
      body: componentBody(node),
    });
  }
  if (node.name === "Error") {
    return $createErrorNode({
      stage: stringAttribute(node, "stage"),
      status: statusAttribute(node, "status"),
      label: stringAttribute(node, "label"),
      body: componentBody(node),
    });
  }
  if (node.name === "Source") {
    return $createSourceNode({
      status: statusAttribute(node, "status"),
      label: stringAttribute(node, "label"),
      body: componentBody(node),
    });
  }
  // Backward compatibility: map old TranscriptBlock to new nodes based on kind
  if (node.name === "TranscriptBlock") {
    const kind = attributeValue(node, "kind");
    const status = statusAttribute(node, "status");
    const label = stringAttribute(node, "label");
    const body = componentBody(node);

    if (kind === "command") {
      return $createCommandNode({
        cmd: stringAttribute(node, "command"),
        exit: nullableNumberAttribute(node, "exit"),
        status,
        label,
        body,
      });
    }
    if (kind === "error") {
      return $createErrorNode({
        stage: stringAttribute(node, "stage"),
        status,
        label,
        body,
      });
    }
    return $createSourceNode({
      status,
      label,
      body,
    });
  }
  return $createMdxSourceNode(sourceForNode(source, node) ?? serializeMdastNode(node));
}

function commandToMdx(node: CommandNode): string {
  const attributes = [
    `cmd=${JSON.stringify(node.getCmd())}`,
    node.getExit() !== null ? `exit={${node.getExit()}}` : "",
    `status=${JSON.stringify(node.getStatus())}`,
    node.getLabel() ? `label=${JSON.stringify(node.getLabel())}` : "",
  ].filter(Boolean).join(" ");
  return [
    `<Command ${attributes}>`,
    node.getBody().trimEnd(),
    `</Command>`,
  ].join("\n");
}

function errorToMdx(node: ErrorNode): string {
  const attributes = [
    node.getStage() ? `stage=${JSON.stringify(node.getStage())}` : "",
    `status=${JSON.stringify(node.getStatus())}`,
    node.getLabel() ? `label=${JSON.stringify(node.getLabel())}` : "",
  ].filter(Boolean).join(" ");
  return [
    `<Error ${attributes}>`,
    node.getBody().trimEnd(),
    `</Error>`,
  ].join("\n");
}

function sourceToMdx(node: SourceNode): string {
  const attributes = [
    `status=${JSON.stringify(node.getStatus())}`,
    node.getLabel() ? `label=${JSON.stringify(node.getLabel())}` : "",
  ].filter(Boolean).join(" ");
  return [
    `<Source ${attributes}>`,
    node.getBody().trimEnd(),
    `</Source>`,
  ].join("\n");
}

function appendText<T extends ElementNode>(node: T, text: string): T {
  if (text) node.append($createTextNode(text));
  return node;
}

function componentBody(node: MdastNode): string {
  return serializeMdastChildren(node).trim();
}

function stringAttribute(node: MdastNode, name: string): string {
  const value = attributeValue(node, name);
  return typeof value === "string" ? value : "";
}

function nullableNumberAttribute(node: MdastNode, name: string): number | null {
  const value = attributeValue(node, name);
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return null;
}

function statusAttribute(node: MdastNode, name: string): ComponentStatus {
  const value = attributeValue(node, name);
  return value === "ok" || value === "error" || value === "pending" || value === "info" ? value : "pending";
}

function attributeValue(node: MdastNode, name: string): unknown {
  const attributes = Array.isArray(node.attributes) ? node.attributes : [];
  const attribute = attributes.find((candidate): candidate is { name?: unknown; value?: unknown } => isRecord(candidate) && candidate.name === name);
  if (!attribute) return undefined;
  if (isRecord(attribute.value) && attribute.value.type === "mdxJsxAttributeValueExpression") return expressionValue(attribute.value.value);
  return attribute.value;
}

function expressionValue(value: unknown): unknown {
  if (value === "null") return null;
  if (typeof value === "string" && Number.isFinite(Number(value))) return Number(value);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function headingTag(depth: unknown): HeadingTagType {
  return `h${depth === 1 || depth === 2 || depth === 3 || depth === 4 || depth === 5 || depth === 6 ? depth : 2}` as HeadingTagType;
}
