import { markdownBlocks } from "./markdown-blocks.js";
import { readPacketBytes } from "./store.js";

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

export async function readPacket(path: string, directory: string, id: string, from?: number, to?: number) {
  const value = await readPacketBytes(path, directory, id);
  if (from === undefined && to === undefined) return value;
  const parsed = JSON.parse(decoder.decode(value));
  if (Array.isArray(parsed)) return encoder.encode(`${JSON.stringify(select(parsed, id, from, to))}\n`);
  if (record(parsed) && parsed.zinc === "text" && typeof parsed.text === "string") {
    if (parsed.format === "markdown") return encoder.encode(select(markdownBlocks(parsed.text), id, from, to).map((block) => block.raw).join(""));
    select([parsed], id, from, to);
    return encoder.encode(parsed.text);
  }
  if (record(parsed) && typeof parsed.zinc === "string") {
    select([parsed], id, from, to);
    return value;
  }
  throw new Error(`Packet ${id} does not support ranged reads`);
}

function select<T>(values: T[], id: string, from?: number, to?: number) {
  const start = from ?? 0, end = to ?? values.length;
  if (!Number.isInteger(start) || start < 0 || !Number.isInteger(end) || end <= start) throw new Error("Packet range must be a non-empty half-open range");
  if (start >= values.length || end > values.length) throw new Error(`Packet range is outside ${id}`);
  return values.slice(start, end);
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
