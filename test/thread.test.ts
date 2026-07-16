import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { decodeHead, encodeHead, normalizeIdentifier, planPatch, prefixHead } from "../src/thread.js";

const head = { blocks: [
  { id: "blk_a", slice: { packet: "pkt_a", to: 1 } },
  { id: "blk_b", slice: { packet: "pkt_b" } },
] };

describe("thread contracts", () => {
  it("round trips stable block heads", () => assert.deepEqual(decodeHead(encodeHead(head)), head));
  it("reads an inclusive stable-id prefix", () => assert.deepEqual(prefixHead(head, "blk_a"), { blocks: [head.blocks[0]] }));
  it("plans reuse, replacement, insertion, deletion, and reorder", () => {
    assert.deepEqual(planPatch(head, {
      revision: "rev_a",
      order: ["blk_b", "blk_a", "blk_c"],
      writes: [
        { id: "blk_a", origins: ["blk_a"], bytes: Uint8Array.of(1) },
        { id: "blk_c", origins: ["blk_b", "blk_b"], bytes: Uint8Array.of(2) },
      ],
    }), [
      { id: "blk_b", reuse: head.blocks[1] },
      { id: "blk_a", origins: [head.blocks[0]], bytes: Uint8Array.of(1) },
      { id: "blk_c", origins: [head.blocks[1], head.blocks[1]], bytes: Uint8Array.of(2) },
    ]);
  });
  it("rejects duplicate order, duplicate writes, unknown origins, and missing new writes", () => {
    assert.throws(() => planPatch(head, { revision: "r", order: ["blk_a", "blk_a"], writes: [] }), /ordered twice/);
    assert.throws(() => planPatch(head, { revision: "r", order: ["blk_a"], writes: [{ id: "blk_a", origins: [], bytes: Uint8Array.of(1) }, { id: "blk_a", origins: [], bytes: Uint8Array.of(2) }] }), /written twice/);
    assert.throws(() => planPatch(head, { revision: "r", order: ["blk_a"], writes: [{ id: "blk_a", origins: ["missing"], bytes: Uint8Array.of(1) }] }), /Unknown block origin/);
    assert.throws(() => planPatch(head, { revision: "r", order: ["blk_new"], writes: [] }), /no write/);
  });
  it("normalizes one-line identifiers", () => {
    assert.equal(normalizeIdentifier("  #zinc   manuscript  "), "#zinc manuscript");
    assert.throws(() => normalizeIdentifier("two\nlines"), /one line/);
  });
});
