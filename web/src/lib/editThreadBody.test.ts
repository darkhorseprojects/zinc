import { describe, expect, it } from "vitest";
import { threadText } from "./threadBody";
import { editThreadBody } from "./editThreadBody";
import type { Packet } from "./types";

const encoder = new TextEncoder();
function packet(id: string, bytes: string): Packet {
  return { id, parent: null, at: 1, bytes: encoder.encode(bytes) };
}

describe("editThreadBody", () => {
  it("reuses unchanged packet ranges", async () => {
    const packets = { a: packet("a", "hello") };
    const text = threadText({ ranges: [{ packet: "a" }] }, packets);
    const created: string[] = [];
    const body = await editThreadBody(text, "hello", async (bytes) => {
      created.push(typeof bytes === "string" ? bytes : new TextDecoder().decode(bytes));
      return packet("new", typeof bytes === "string" ? bytes : new TextDecoder().decode(bytes));
    });
    expect(created).toEqual([]);
    expect(body).toEqual({ ranges: [{ packet: "a", to: 5 }] });
  });

  it("creates one middle packet for edits", async () => {
    const packets = { a: packet("a", "hello world") };
    const text = threadText({ ranges: [{ packet: "a" }] }, packets);
    const created: string[] = [];
    const body = await editThreadBody(text, "hello zinc world", async (bytes) => {
      created.push(typeof bytes === "string" ? bytes : new TextDecoder().decode(bytes));
      return packet("new", typeof bytes === "string" ? bytes : new TextDecoder().decode(bytes));
    });
    expect(created).toEqual(["zinc "]);
    expect(body.ranges).toEqual([{ packet: "a", to: 6 }, { packet: "new" }, { packet: "a", from: 6, to: 11 }]);
  });

  it("omits deleted middle bytes", async () => {
    const packets = { a: packet("a", "hello zinc world") };
    const text = threadText({ ranges: [{ packet: "a" }] }, packets);
    const body = await editThreadBody(text, "hello world", async (bytes) => {
      return packet("new", typeof bytes === "string" ? bytes : new TextDecoder().decode(bytes));
    });
    expect(body.ranges).toEqual([{ packet: "a", to: 6 }, { packet: "a", from: 11, to: 16 }]);
  });
});
