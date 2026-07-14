import { Marked } from "marked";

const marked = new Marked();

export type MarkdownBlock = { type: string; raw: string } & Record<string, unknown>;

export function markdownBlocks(markdown: string): MarkdownBlock[] {
  return (marked.lexer(markdown) as MarkdownBlock[]).filter((token) => token?.type !== "space");
}
