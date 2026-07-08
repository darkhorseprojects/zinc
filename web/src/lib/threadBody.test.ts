import { describe, expect, it } from "vitest";
import { encodeThreadBody, decodeThreadBody, threadText, normalizeThreadBody, threadPacketIds } from "./threadBody";
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
});
