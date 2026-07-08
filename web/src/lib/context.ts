import { rangeText, threadText } from "./threadBody";
import type { Packet, ThreadBody, TextRange } from "./types";

/**
 * Builds the prepared loop input for a Thread: a raw tail (most recent `rawContextBytes`
 * of packet text), sequential head packet refs, and Fibonacci-spaced middle packet refs.
 */
export function threadContext(body: ThreadBody, packets: Record<string, Packet>, rawContextBytes = 8192): string {
  const ranges = threadText(body, packets).ranges;
  if (ranges.length === 0) return "";

  const tailStartIndex = tailStart(ranges, rawContextBytes);
  if (tailStartIndex === 0) return contextRawSection("Raw thread", ranges, packets);

  const headEndIndex = headEnd(ranges, tailStartIndex, rawContextBytes);
  const headRanges = ranges.slice(0, headEndIndex);
  const middleRanges = fibonacciMiddle(ranges.slice(headEndIndex, tailStartIndex));
  const tail = ranges.slice(tailStartIndex);

  return [
    headRanges.length ? contextRefSection("Head packet refs", headRanges) : "",
    middleRanges.length ? contextRefSection("Middle packet refs", middleRanges) : "",
    tail.length ? contextRawSection("Raw tail", tail, packets) : "",
  ].filter(Boolean).join("\n\n");
}

function tailStart(ranges: TextRange[], rawContextBytes: number): number {
  let bytes = 0;
  let start = ranges.length;
  for (let i = ranges.length - 1; i >= 0; i--) {
    const size = ranges[i].byteTo - ranges[i].byteFrom;
    if (bytes === 0 || bytes + size <= rawContextBytes) {
      bytes += size;
      start = i;
    } else break;
  }
  return start;
}

function headEnd(ranges: TextRange[], tailStartIndex: number, rawContextBytes: number): number {
  let bytes = 0;
  let end = 0;
  for (let i = 0; i < tailStartIndex; i++) {
    const size = ranges[i].byteTo - ranges[i].byteFrom;
    if (bytes === 0 || bytes + size <= rawContextBytes) {
      bytes += size;
      end = i + 1;
    } else break;
  }
  return end;
}

/** Fibonacci-spaced offsets (1, 2, 3, 5, 8, 13, ...) into `pool`, plus the last element always included. */
function fibonacciMiddle(pool: TextRange[]): TextRange[] {
  if (!pool.length) return [];
  const selected = new Set<number>();
  let a = 1;
  let b = 2;
  while (a <= pool.length) {
    selected.add(a - 1);
    const next = a + b;
    a = b;
    b = next;
  }
  selected.add(pool.length - 1);
  return pool.filter((_, i) => selected.has(i));
}

function contextRawSection(title: string, ranges: TextRange[], packets: Record<string, Packet>) {
  if (!ranges.length) return "";
  return [`# ${title}`, ranges.map((range) => rangeText(range.packet, packets)).join("\n")].join("\n\n");
}

function contextRefSection(title: string, ranges: TextRange[]) {
  const lines = [`# ${title}`];
  for (const range of ranges) {
    const { packet, from, to } = range.packet;
    const rangeArg = from !== undefined || to !== undefined ? ` ${from ?? ""}:${to ?? ""}` : "";
    lines.push(`- ${packet}${rangeArg}`);
  }
  return lines.join("\n");
}
