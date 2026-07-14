import { describe, expect, it } from "vitest";
import { decodeHead, encodeHead, normalizeIdentifier, planPatch, prefixHead } from "../src/thread.js";

const head = { blocks: [
  { id: "blk_a", slice: { packet: "pkt_a", to: 1 } },
  { id: "blk_b", slice: { packet: "pkt_b" } },
] };

describe("thread contracts", () => {
  it("round trips stable block heads", () => expect(decodeHead(encodeHead(head))).toEqual(head));
  it("reads an inclusive stable-id prefix", () => expect(prefixHead(head, "blk_a")).toEqual({ blocks: [head.blocks[0]] }));
  it("plans reuse, replacement, insertion, deletion, and reorder", () => {
    expect(planPatch(head, {
      revision: "rev_a",
      order: ["blk_b", "blk_a", "blk_c"],
      writes: [
        { id: "blk_a", origins: ["blk_a"], bytes: Uint8Array.of(1) },
        { id: "blk_c", origins: ["blk_b", "blk_b"], bytes: Uint8Array.of(2) },
      ],
    })).toEqual([
      { id: "blk_b", reuse: head.blocks[1] },
      { id: "blk_a", origins: [head.blocks[0]], bytes: Uint8Array.of(1) },
      { id: "blk_c", origins: [head.blocks[1], head.blocks[1]], bytes: Uint8Array.of(2) },
    ]);
  });
  it("rejects duplicate order, duplicate writes, unknown origins, and missing new writes", () => {
    expect(() => planPatch(head, { revision: "r", order: ["blk_a", "blk_a"], writes: [] })).toThrow(/ordered twice/);
    expect(() => planPatch(head, { revision: "r", order: ["blk_a"], writes: [{ id: "blk_a", origins: [], bytes: Uint8Array.of(1) }, { id: "blk_a", origins: [], bytes: Uint8Array.of(2) }] })).toThrow(/written twice/);
    expect(() => planPatch(head, { revision: "r", order: ["blk_a"], writes: [{ id: "blk_a", origins: ["missing"], bytes: Uint8Array.of(1) }] })).toThrow(/Unknown block origin/);
    expect(() => planPatch(head, { revision: "r", order: ["blk_new"], writes: [] })).toThrow(/no write/);
  });
  it("normalizes one-line identifiers", () => {
    expect(normalizeIdentifier("  #zinc   manuscript  ")).toBe("#zinc manuscript");
    expect(() => normalizeIdentifier("two\nlines")).toThrow(/one line/);
  });
});
