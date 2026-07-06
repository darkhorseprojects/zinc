import remarkGfm from "remark-gfm";
import remarkMdx from "remark-mdx";
import remarkParse from "remark-parse";
import { unified } from "unified";

export type MdastNode = {
  type: string;
  value?: string;
  depth?: number;
  lang?: string | null;
  name?: string | null;
  ordered?: boolean;
  children?: MdastNode[];
  position?: {
    start?: { offset?: number };
    end?: { offset?: number };
  };
  [key: string]: unknown;
};

export type MdastRoot = MdastNode & {
  type: "root";
  children: MdastNode[];
};

export type MdxParseResult =
  | { ok: true; source: string; root: MdastRoot }
  | { ok: false; source: string; error: unknown };

const processor = unified().use(remarkParse).use(remarkMdx).use(remarkGfm);

export function parseMdx(source: string): MdxParseResult {
  try {
    const root = processor.parse(source) as MdastRoot;
    return { ok: true, source, root };
  } catch (error) {
    return { ok: false, source, error };
  }
}

export function sourceForNode(source: string, node: MdastNode): string | null {
  const start = node.position?.start?.offset;
  const end = node.position?.end?.offset;
  if (typeof start !== "number" || typeof end !== "number") return null;
  if (start < 0 || end < start || end > source.length) return null;
  return source.slice(start, end);
}
