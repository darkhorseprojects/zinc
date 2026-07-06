import { gfmToMarkdown } from "mdast-util-gfm";
import { mdxToMarkdown } from "mdast-util-mdx";
import { toMarkdown } from "mdast-util-to-markdown";
import type { MdastNode, MdastRoot } from "./parseMdx";

const markdownExtensions = {
  extensions: [gfmToMarkdown(), mdxToMarkdown()],
  bullet: "-" as const,
  rule: "-" as const,
};

export function serializeMdx(root: MdastRoot): string {
  return toMarkdown(root as never, markdownExtensions).trimEnd();
}

export function serializeMdastNode(node: MdastNode): string {
  return serializeMdx({ type: "root", children: [node] });
}

export function serializeMdastChildren(node: MdastNode): string {
  return serializeMdx({ type: "root", children: node.children ?? [] });
}
