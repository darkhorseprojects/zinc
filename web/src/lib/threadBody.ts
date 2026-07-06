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

export function threadContext(
  body: ThreadBody,
  packets: Record<string, Packet>,
  rawContextBytes = 8192,
  storePath = "STORE",
): string {
  const text = threadText(body, packets);
  const ranges = text.ranges;

  if (ranges.length === 0) return "";

  // --- Tail: walk backward, collect raw ranges up to rawContextBytes ---
  let tailBytes = 0;
  let tailStartIndex = ranges.length;
  for (let i = ranges.length - 1; i >= 0; i--) {
    const size = ranges[i].byteTo - ranges[i].byteFrom;
    if (tailBytes === 0 || tailBytes + size <= rawContextBytes) {
      tailBytes += size;
      tailStartIndex = i;
    } else break;
  }

  // Whole thread fits in raw tail
  if (tailStartIndex === 0) return contextRawSection("Raw thread", ranges, packets);

  // --- Head refs: walk forward, collect packet refs up to rawContextBytes ---
  let headBytes = 0;
  let headEndIndex = 0;
  for (let i = 0; i < tailStartIndex; i++) {
    const size = ranges[i].byteTo - ranges[i].byteFrom;
    if (headBytes === 0 || headBytes + size <= rawContextBytes) {
      headBytes += size;
      headEndIndex = i + 1;
    } else break;
  }

  const headRanges = ranges.slice(0, headEndIndex);

  // --- Middle refs: Fibonacci-spaced between head end and tail start ---
  const middleRanges: TextRange[] = [];
  const middlePool = ranges.slice(headEndIndex, tailStartIndex);

  if (middlePool.length > 0) {
    const selected = new Set<number>();
    // Fibonacci offsets from headEndIndex: 1, 2, 3, 5, 8, 13, ...
    let a = 1, b = 2;
    while (a <= middlePool.length) {
      selected.add(a - 1); // convert 1-based offset to 0-based pool index
      const next = a + b;
      a = b;
      b = next;
    }
    // Always include last middle range
    selected.add(middlePool.length - 1);

    for (let i = 0; i < middlePool.length; i++) {
      if (selected.has(i)) middleRanges.push(middlePool[i]);
    }
  }

  const tail = ranges.slice(tailStartIndex);

  const parts: string[] = [];
  if (headRanges.length) parts.push(contextRefSection("Head packet refs", headRanges));
  if (middleRanges.length) parts.push(contextRefSection("Middle packet refs", middleRanges));
  if (tail.length) parts.push(contextRawSection("Raw tail", tail, packets));
  return parts.filter(Boolean).join("\n\n");
}

function contextRawSection(title: string, ranges: TextRange[], packets: Record<string, Packet>) {
  if (!ranges.length) return "";
  return [`# ${title}`, ...ranges.map(range => contextRawRange(range, packets))].join("\n\n");
}

function contextRawRange(range: TextRange, packets: Record<string, Packet>) {
  const author = range.packet.author ? ` author=${range.packet.author}` : "";
  return `<!-- packet=${range.packet.packet}${author} -->\n${rangeText(range.packet, packets)}`;
}

function contextRefSection(title: string, ranges: TextRange[]) {
  if (!ranges.length) return "";
  const lines = [`# ${title}`];
  for (const range of ranges) {
    const packetRange = range.packet;
    const packet = packetRange.packet;
    const rangeArg = (packetRange.from !== undefined || packetRange.to !== undefined)
      ? ` range: ${packetRange.from ?? ""}:${packetRange.to ?? ""}`
      : "";
    lines.push(`- packet: ${packet}${rangeArg}`);
  }
  return lines.join("\n");
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
