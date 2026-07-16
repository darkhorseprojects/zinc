import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { decodeBlock, documentFromNodes, documentNodes, encodeBlock, markdownPacket, textPacket } from "../web/src/editor/codec.js";
import { markdownToNodes, nodesToMarkdown } from "../web/src/markdown.js";
import { identifierSuggestion, parseIdentifier, tagColor } from "../web/src/thread/identifier.js";

const encoder = new TextEncoder(), packet = (value: unknown) => encoder.encode(`${JSON.stringify(value)}\n`);
describe("Web block boundary", () => {
  it("projects canonical Markdown without infrastructure nodes", () => {
    const decoded = decodeBlock(markdownPacket("# Heading\n\n**bold** and [link](https://example.com)")), source = JSON.stringify(decoded.document);
    assert.doesNotMatch(source, /"type":"packet"/);
    assert.doesNotMatch(source, /"type":"markdown-marker"/);
    assert.match(source, /"detail":2/);
    assert.deepEqual(encodeBlock("markdown", decoded.document), markdownPacket("# Heading\n\n**bold** and [link](https://example.com)"));
  });
  it("round trips GFM tables as rich structure with exact source", () => {
    const source = "| Name | Value |\n| --- | --- |\n| alpha | **one** |", nodes = markdownToNodes(source);
    assert.equal(nodes[0].type, "table");
    assert.equal(nodesToMarkdown(nodes), source);
  });
  it("retains inline and display equation source in EquationNode", () => {
    const inline = decodeBlock(markdownPacket("Energy $E=mc^2$ today.")), children = documentNodes(inline.document)[0].children as any[];
    assert.deepEqual(children.map((child) => child.type), ["text", "equation", "text"]);
    assert.equal(children[1].source, "$E=mc^2$");
    assert.equal(JSON.parse(new TextDecoder().decode(encodeBlock("markdown", inline.document))).text, "Energy $E=mc^2$ today.");
    const display = decodeBlock(markdownPacket("$$\nx^2+y^2\n$$"));
    assert.deepEqual((documentNodes(display.document)[0].children as any[])[0], { type: "equation", version: 1, source: "$$\nx^2+y^2\n$$" });
  });
  it("keeps TSX preview as the default and source as canonical", () => {
    const decoded = decodeBlock(textPacket("tsx", "export default () => <button>ok</button>"));
    assert.equal(documentNodes(decoded.document)[0].type, "tsx-preview");
    assert.match(JSON.parse(new TextDecoder().decode(encodeBlock("tsx", decoded.document))).text, /<button>/);
  });
  it("retains reasoning, shell, recall, and error product nodes", () => {
    assert.equal(documentNodes(decodeBlock(textPacket("reasoning", "think")).document)[0].type, "reasoning");
    const directReasoning = documentFromNodes([{ type: "reasoning", version: 1, children: [{ detail: 0, format: 0, mode: "normal", style: "", text: "think", type: "text", version: 1 }] }]);
    assert.deepEqual(encodeBlock("reasoning", directReasoning), textPacket("reasoning", "think"));
    assert.equal(documentNodes(decodeBlock(textPacket("error", "bad")).document)[0].type, "error");
    assert.deepEqual(documentNodes(decodeBlock(packet({ zinc: "shell", command: "ls", output: "file" })).document)[0], { type: "shell", version: 1, command: "ls", output: "file" });
    assert.deepEqual(documentNodes(decodeBlock(packet({ zinc: "recall", packet: "pkt_a", content: "old" })).document)[0], { type: "recall", version: 1, packet: "pkt_a", content: "old" });
    const fenced = markdownToNodes("```shell\necho ok\n```");
    assert.equal(fenced[0].type, "code");
    assert.equal(fenced[0].language, "shell");
    assert.equal(nodesToMarkdown(fenced), "```shell\necho ok\n```");
  });
  it("canonicalizes tags first and derives deterministic colors", () => {
    assert.deepEqual(parseIdentifier("Manuscript #editor #zinc"), { value: "#editor #zinc Manuscript", tags: ["#editor", "#zinc"], title: "Manuscript" });
    assert.equal(tagColor("#editor"), tagColor("#editor"));
    assert.ok(identifierSuggestion("# A **long** manuscript title with more than seven words here").split(" ").length <= 7);
  });
});
