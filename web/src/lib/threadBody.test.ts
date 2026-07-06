import { describe, expect, it } from "vitest";
import { encodeThreadBody, decodeThreadBody, threadText, threadContext, normalizeThreadBody, threadPacketIds } from "./threadBody";
import type { Packet } from "./types";

const encoder = new TextEncoder();
function packet(id: string, bytes: string): Packet {
  return { id, parent: null, at: 1, bytes: encoder.encode(bytes) };
}

describe("thread body", () => {
  it("encodes and decodes packet ranges", () => {
    const pkt = packet("body", JSON.stringify({ ranges: [{ packet: "a" }, { packet: "b", from: 1, to: 3 }] }));
    expect(decodeThreadBody(pkt)).toEqual({ ranges: [{ packet: "a" }, { packet: "b", from: 1, to: 3 }] });
    expect(decodeThreadBody(packet("encoded", new TextDecoder().decode(encodeThreadBody({ ranges: [{ packet: "a" }] }))))).toEqual({ ranges: [{ packet: "a" }] });
  });

  it("maps byte ranges into thread text", () => {
    const packets = { a: packet("a", "abcdef"), b: packet("b", "ghi") };
    const text = threadText({ ranges: [{ packet: "a", from: 1, to: 4 }, { packet: "b" }] }, packets);
    expect(text.mdx).toBe("bcdghi");
    expect(text.byteLength).toBe(6);
    expect(text.ranges).toHaveLength(2);
  });

  it("normalizes adjacent ranges", () => {
    expect(normalizeThreadBody({ ranges: [{ packet: "a", to: 2 }, { packet: "a", from: 2, to: 4 }] })).toEqual({ ranges: [{ packet: "a", to: 4 }] });
    expect(threadPacketIds({ ranges: [{ packet: "a" }, { packet: "a", from: 1 }, { packet: "b" }] })).toEqual(["a", "b"]);
  });

  it("builds full raw thread for small threads", () => {
    const packets = {
      p1: packet("p1", "hello"),
      p2: packet("p2", "world"),
    };
    const context = threadContext({ ranges: [
      { packet: "p1", author: "user" },
      { packet: "p2", author: "assistant" },
    ] }, packets, 100, "/tmp/zinc.db");

    expect(context).toBe([
      "# Raw thread",
      "<!-- packet=p1 author=user -->\nhello",
      "<!-- packet=p2 author=assistant -->\nworld",
    ].join("\n\n"));
  });

  it("builds context with head refs, no middle, and raw tail", () => {
    const packets = {
      p1: packet("p1", "head-user"),       // 9 bytes
      p2: packet("p2", "tail-assistant"),  // 14 bytes
    };

    // rawContextBytes=14: tail fits p2 (14 bytes); head refs p1 (9 bytes <= 14)
    const context = threadContext({ ranges: [
      { packet: "p1", author: "user" },
      { packet: "p2", author: "assistant" },
    ] }, packets, 14, "/tmp/zinc.db");

    expect(context).toContain("# Head packet refs");
    expect(context).toContain("- packet: p1");
    expect(context).not.toContain("<!-- packet=p1");
    expect(context).toContain("# Raw tail");
    expect(context).toContain("<!-- packet=p2 author=assistant -->\ntail-assistant");
  });

  it("builds context with Fibonacci-spaced middle refs", () => {
    // 8 packets: p1(head) p2..p7(middle pool of 6) p8(tail)
    // Each packet: 10 bytes. rawContextBytes=10 → tail=p8, head=p1, middle pool=p2..p7
    // Fibonacci offsets from pool start: 1,2,3,5 → pool indices 0,1,2,4 → p2,p3,p4,p6
    // Plus always include last middle (pool index 5 → p7)
    // Selected middle: p2,p3,p4,p6,p7
    const pkts: Record<string, Packet> = {};
    for (let i = 1; i <= 8; i++) pkts[`p${i}`] = packet(`p${i}`, `${"x".repeat(9)}${i}`);

    const body = { ranges: [1,2,3,4,5,6,7,8].map(i => ({ packet: `p${i}` })) };
    const context = threadContext(body, pkts, 10, "/tmp/zinc.db");

    expect(context).toContain("# Head packet refs");
    expect(context).toContain("- packet: p1");
    expect(context).toContain("# Middle packet refs");
    expect(context).toContain("- packet: p2");
    expect(context).toContain("- packet: p3");
    expect(context).toContain("- packet: p4");
    expect(context).toContain("- packet: p6");
    expect(context).toContain("- packet: p7");
    // p5 is NOT at a Fibonacci offset (offsets 1,2,3,5 → pool[0,1,2,4] = p2,p3,p4,p6)
    expect(context).not.toContain("- packet: p5");
    expect(context).toContain("# Raw tail");
    expect(context).toContain("<!-- packet=p8");
  });

  it("emits --range for sliced packet refs", () => {
    const packets = {
      p1: packet("p1", "abcdefghij"), // 10 bytes
      p2: packet("p2", "klmnopqrst"), // 10 bytes
    };
    // rawContextBytes=10: tail=p2, head ref=p1 (sliced from:2 to:8)
    const body = { ranges: [{ packet: "p1", from: 2, to: 8 }, { packet: "p2" }] };
    const context = threadContext(body, packets, 10, "/tmp/zinc.db");

    expect(context).toContain("# Head packet refs");
    expect(context).toContain("- packet: p1 range: 2:8");
    expect(context).toContain("# Raw tail");
  });
});
