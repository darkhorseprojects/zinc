import { describe, expect, it } from "vitest";
import { createSolidLexicalEditor } from "~/thread/lexical";
import { exportLexicalToMdx, importMdxToLexical, zincLexicalNodes } from "./mdx";

function editor() {
  return createSolidLexicalEditor({
    namespace: "zinc-mdx-test",
    nodes: zincLexicalNodes,
    onError(error) {
      throw error;
    },
  });
}

describe("thread mdx pipeline", () => {
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

  it("roundtrips a known component tag through the generic node", () => {
    const lexical = editor();
    const source = "<Reasoning>\nthink\n</Reasoning>";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips a component with attributes", () => {
    const lexical = editor();
    const source = `<Shell cmd="bun test" exit={0} status="ok" label="respond">\npassed\n</Shell>`;
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips an arbitrary custom tag the model or user might write", () => {
    const lexical = editor();
    const source = "<Chart data={1} label=\"revenue\">\nkeep me\n</Chart>";
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
    const source = "- item one\n- item two\n\n1. first\n2. second";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips thematic breaks", () => {
    const lexical = editor();
    const source = "first section\n\n---\n\nsecond section";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });

  it("roundtrips a trailing-space soft line break", () => {
    const lexical = editor();
    const source = "hello  \nworld";
    importMdxToLexical(lexical, source);
    expect(exportLexicalToMdx(lexical)).toBe(source);
  });
});
