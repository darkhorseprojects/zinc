import { describe, expect, it } from "vitest";
import { threadContext } from "./context";
import type { Packet, ThreadBody } from "./types";

const enc = new TextEncoder();

function packet(id: string, text: string): Packet {
  return { id, parent: null, at: 0, bytes: enc.encode(text) };
}

describe("threadContext", () => {
  it("feeds small threads as raw text without packet metadata", () => {
    const packets = {
      p1: packet("p1", "hello\n"),
      p2: packet("p2", "world\n"),
    };
    const body: ThreadBody = { ranges: [{ packet: "p1", author: "user" }, { packet: "p2", author: "assistant" }] };

    expect(threadContext(body, packets, 100)).toBe("# Raw thread\n\nhello\n\nworld\n");
  });

  it("uses compact packet refs outside the raw tail", () => {
    const packets = {
      p1: packet("p1", "aaa\n"),
      p2: packet("p2", "bbb\n"),
      p3: packet("p3", "ccc\n"),
    };
    const body: ThreadBody = { ranges: [{ packet: "p1", from: 1, to: 3 }, { packet: "p2" }, { packet: "p3" }] };

    expect(threadContext(body, packets, 4)).toBe("# Head packet refs\n- p1 1:3\n\n# Middle packet refs\n- p2\n\n# Raw tail\n\nccc\n");
  });
});
