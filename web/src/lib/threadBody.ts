import type { PacketRange, ThreadBody, Packet, TextRange, ThreadText } from "./types";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function emptyThreadBody(): ThreadBody {
  return { ranges: [] };
}

export function encodeThreadBody(body: ThreadBody) {
  return encoder.encode(`${JSON.stringify({ ranges: normalizeThreadBody(body).ranges })}\n`);
}

export function decodeThreadBody(packet: Packet): ThreadBody | null {
  return decodeThreadBodyBytes(packet.bytes);
}

export function decodeThreadBodyBytes(bytes: Uint8Array): ThreadBody | null {
  try {
    const value = JSON.parse(decoder.decode(bytes));
    if (!isRecord(value) || !Array.isArray(value.ranges)) return null;
    const ranges = value.ranges.map(decodeRange);
    if (ranges.some((range) => !range)) return null;
    return normalizeThreadBody({ ranges: ranges as PacketRange[] });
  } catch {
    return null;
  }
}

export function packetText(packet: Packet) {
  return decoder.decode(packet.bytes);
}

export function rangeBytes(range: PacketRange, packets: Record<string, Packet>) {
  const packet = packets[range.packet];
  if (!packet) return new Uint8Array();
  const from = range.from ?? 0;
  const to = range.to ?? packet.bytes.byteLength;
  return packet.bytes.slice(from, to);
}

export function rangeText(range: PacketRange, packets: Record<string, Packet>) {
  return decoder.decode(rangeBytes(range, packets));
}

export function threadPacketIds(body: ThreadBody) {
  return [...new Set(body.ranges.map((range) => range.packet))];
}

export function threadText(body: ThreadBody, packets: Record<string, Packet>): ThreadText {
  let mdx = "";
  let byteOffset = 0;
  const ranges: TextRange[] = [];

  for (const packetRange of body.ranges) {
    const bytes = rangeBytes(packetRange, packets);
    if (!bytes.byteLength) continue;
    const text = decoder.decode(bytes);
    const textFrom = mdx.length;
    const textTo = textFrom + text.length;
    const byteFrom = byteOffset;
    const byteTo = byteFrom + bytes.byteLength;
    mdx += text;
    byteOffset = byteTo;
    ranges.push({ packet: normalizeRange(packetRange), textFrom, textTo, byteFrom, byteTo });
  }

  return { mdx, ranges, byteLength: byteOffset };
}

export function threadLabel(body: ThreadBody, packets: Record<string, Packet>) {
  const text = threadText(body, packets).mdx.replace(/<[^>]+>/g, " ").trim();
  if (text) return text.split(/\s+/).slice(0, 7).join(" ").slice(0, 60);
  return "New thread";
}

export function normalizeThreadBody(body: ThreadBody): ThreadBody {
  const ranges: PacketRange[] = [];

  for (const range of body.ranges.map(normalizeRange)) {
    const from = range.from ?? 0;
    const to = range.to;
    if (to !== undefined && to <= from) continue;

    const previous = ranges.at(-1);
    if (previous && previous.packet === range.packet && (previous.to ?? undefined) === from && previous.author === range.author) {
      previous.to = to;
      continue;
    }

    ranges.push(range);
  }

  return { ranges };
}

export function utf8ByteLength(value: string) {
  return encoder.encode(value).byteLength;
}

export function stringToBytes(value: string) {
  return encoder.encode(value);
}

function decodeRange(value: unknown): PacketRange | null {
  if (!isRecord(value) || typeof value.packet !== "string") return null;
  if (value.from !== undefined && !isOffset(value.from)) return null;
  if (value.to !== undefined && !isOffset(value.to)) return null;
  if (typeof value.from === "number" && typeof value.to === "number" && value.to < value.from) return null;
  const author = value.author === "user" || value.author === "assistant" || value.author === "system" ? value.author : undefined;
  return normalizeRange({
    packet: value.packet,
    ...(typeof value.from === "number" ? { from: value.from } : {}),
    ...(typeof value.to === "number" ? { to: value.to } : {}),
    ...(author ? { author } : {}),
  });
}

function normalizeRange(range: PacketRange): PacketRange {
  const from = range.from && range.from > 0 ? range.from : undefined;
  return {
    packet: range.packet,
    ...(from !== undefined ? { from } : {}),
    ...(range.to !== undefined ? { to: range.to } : {}),
    ...(range.author ? { author: range.author } : {}),
  };
}

function isOffset(value: unknown) {
  return Number.isInteger(value) && Number(value) >= 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
