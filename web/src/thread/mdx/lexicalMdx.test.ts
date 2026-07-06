import { describe, expect, it } from "vitest";
import { $createLineBreakNode, $createParagraphNode, $createTextNode, $getRoot } from "lexical";
import { createSolidLexicalEditor } from "~/thread/lexical";
import { exportLexicalToMdx, importMdxToLexical, zincLexicalNodes } from "./lexicalMdx";

function editor() {
  return createSolidLexicalEditor({
    namespace: "zinc-mdx-test",
    nodes: zincLexicalNodes,
    onError(error) {
      throw error;
    },
  });
}

describe("Lexical MDX pipeline", () => {
  it("roundtrips a paragraph", () => {
    const lexical = editor();
    importMdxToLexical(lexical, "hello Zinc");
    expect(exportLexicalToMdx(lexical)).toBe("hello Zinc");
  });

  it("roundtrips a heading", () => {
    const lexical = editor();
    importMdxToLexical(lexical, "## Plan");
    expect(exportLexicalToMdx(lexical)).toBe("## Plan");
  });

  it("roundtrips a fenced code block", () => {
    const lexical = editor();
    importMdxToLexical(lexical, "```ts\nconst zinc = true;\n```");
    expect(exportLexicalToMdx(lexical)).toBe("```ts\nconst zinc = true;\n```");
  });

  it("imports and exports Reasoning as a known component node", () => {
    const lexical = editor();
    const source = "<Reasoning>\nthink\n</Reasoning>";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("imports and exports TranscriptBlock as a known component node", () => {
    const lexical = editor();
    const source = `<TranscriptBlock kind="source" status="ok" label="respond" command="bun test" exit={0}>\npassed\n</TranscriptBlock>`;
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("preserves unknown MDX source as an exact top-level slice", () => {
    const lexical = editor();
    const source = "<UnknownWidget value={1}>\nkeep me\n</UnknownWidget>";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips rich inline formatting", () => {
    const lexical = editor();
    const source = "This is **bold** and *italic* and `code` formatting and [a link](https://google.com).";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips lists", () => {
    const lexical = editor();
    const source = "- item one\n\n- item two\n\n1. first\n\n2. second";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips thematic breaks", () => {
    const lexical = editor();
    const source = "first section\n\n---\n\nsecond section";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("exports Shift+Enter soft breaks as markdown line breaks", () => {
    const lexical = editor();
    lexical.update(() => {
      const root = $getRoot();
      root.clear();
      const paragraph = $createParagraphNode();
      paragraph.append($createTextNode("hello"), $createLineBreakNode(), $createTextNode("world"));
      root.append(paragraph);
    }, { discrete: true });
    expect(exportLexicalToMdx(lexical)).toBe("hello\\\nworld");
  });

  it("imports markdown line breaks as soft breaks", () => {
    const lexical = editor();
    importMdxToLexical(lexical, "hello  \nworld");
    expect(exportLexicalToMdx(lexical)).toBe("hello\\\nworld");
  });
});
