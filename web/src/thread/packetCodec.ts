import type { Packet, ThreadView } from "~/lib/types";

/** `wire.ts` always base64-encodes packet bytes for transport, so decoding a wire packet has exactly one real case. */
export function normalizeThreadView(raw: any): ThreadView {
  return { ...raw, packets: Object.fromEntries(Object.entries(raw.packets ?? {}).map(([id, packet]) => [id, normalizePacket(packet)])) };
}

export function normalizePacket(raw: any): Packet {
  return { ...raw, bytes: decodeBase64(raw.bytes) };
}

function decodeBase64(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
  return new Uint8Array();
}
