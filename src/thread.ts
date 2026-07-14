export type Role = "user" | "agent" | "system";
export type Slice = { packet: string; from?: number; to?: number };
export type BlockRef = { id: string; slice: Slice };
export type Head = { blocks: BlockRef[] };

export type BlockDescriptor = {
  id: string;
  role: Role;
  author: string;
  sourceCount: number;
  byteLength: number;
};
export type ThreadSummary = { id: string; identifier: string; revision: string; updated: number };
export type ForkPointDescriptor = { id: string; block: string; members: ThreadSummary[] };
export type ThreadManifest = {
  id: string;
  revision: string;
  identifier: string;
  blocks: BlockDescriptor[];
  forkPoints: ForkPointDescriptor[];
};
export type BlockPayload = { id: string; bytes: Uint8Array; sources: Slice[] };
export type ContextPart = BlockPayload & { slice: Slice; role: Role; author: string };
export type Context = { revision: string; parts: ContextPart[] };

export type BlockWrite = { id: string; origins: string[]; bytes: Uint8Array };
export type ThreadPatch = { revision: string; identifier?: string; order: string[]; writes: BlockWrite[] };
export type PlannedBlock =
  | { id: string; reuse: BlockRef }
  | { id: string; origins: BlockRef[]; bytes: Uint8Array };

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function encodeHead(head: Head) {
  validateHead(head);
  return encoder.encode(`${JSON.stringify({ blocks: head.blocks.map((block) => ({ id: block.id, ...normalizeSlice(block.slice) })) })}\n`);
}

export function decodeHead(bytes: Uint8Array): Head {
  const value = JSON.parse(decoder.decode(bytes));
  if (!record(value) || !Array.isArray(value.blocks)) throw new Error("Invalid thread head");
  const head = { blocks: value.blocks.map((block): BlockRef => {
    if (!record(block) || typeof block.id !== "string") throw new Error("Invalid thread block");
    return { id: block.id, slice: normalizeSlice(block as unknown as Slice) };
  }) };
  validateHead(head);
  return head;
}

export function prefixHead(head: Head, through?: string | null): Head {
  if (!through) return { blocks: head.blocks.map(copyBlock) };
  const index = head.blocks.findIndex((block) => block.id === through);
  if (index < 0) throw new Error(`Unknown prefix block: ${through}`);
  return { blocks: head.blocks.slice(0, index + 1).map(copyBlock) };
}

export function planPatch(head: Head, patch: ThreadPatch): PlannedBlock[] {
  if (!patch || typeof patch.revision !== "string" || !patch.revision) throw new Error("Thread patch revision is required");
  if (patch.identifier !== undefined) normalizeIdentifier(patch.identifier);
  if (!Array.isArray(patch.order) || !Array.isArray(patch.writes)) throw new Error("Invalid thread patch");
  const base = new Map(head.blocks.map((block) => [block.id, block] as const));
  const order = new Set<string>();
  for (const id of patch.order) {
    if (typeof id !== "string" || !id) throw new Error("Invalid block id");
    if (order.has(id)) throw new Error(`Block ordered twice: ${id}`);
    order.add(id);
  }
  const writes = new Map<string, BlockWrite>();
  for (const write of patch.writes) {
    if (!write || typeof write.id !== "string" || !write.id || !Array.isArray(write.origins) || !(write.bytes instanceof Uint8Array) || !write.bytes.byteLength) throw new Error("Invalid block write");
    if (writes.has(write.id)) throw new Error(`Block written twice: ${write.id}`);
    if (!order.has(write.id)) throw new Error(`Written block is not ordered: ${write.id}`);
    for (const origin of write.origins) if (typeof origin !== "string" || !base.has(origin)) throw new Error(`Unknown block origin: ${origin}`);
    writes.set(write.id, write);
  }
  return patch.order.map((id) => {
    const write = writes.get(id), current = base.get(id);
    if (!write) {
      if (!current) throw new Error(`New block has no write: ${id}`);
      return { id, reuse: copyBlock(current) };
    }
    return { id, origins: write.origins.map((origin) => copyBlock(base.get(origin)!)), bytes: write.bytes };
  });
}

export function normalizeIdentifier(value: string) {
  if (typeof value !== "string" || /[\r\n\0]/.test(value)) throw new Error("Thread identifier must be one line");
  const normalized = value.trim().replace(/[\t ]+/g, " ");
  if ([...normalized].length > 96) throw new Error("Thread identifier must be at most 96 characters");
  return normalized;
}

export function normalizeSlice(value: Slice): Slice {
  if (!value || typeof value.packet !== "string" || !value.packet) throw new Error("Invalid packet slice");
  const from = value.from ?? 0, to = value.to;
  if (!Number.isInteger(from) || from < 0 || to !== undefined && (!Number.isInteger(to) || to <= from)) throw new Error("Invalid packet slice");
  return { packet: value.packet, ...(from ? { from } : {}), ...(to === undefined ? {} : { to }) };
}

export function sameSlice(left: Slice, right: Slice) {
  return left.packet === right.packet && (left.from ?? 0) === (right.from ?? 0) && left.to === right.to;
}
export function equalBlocks(left: BlockRef[], right: BlockRef[]) {
  return left.length === right.length && left.every((block, index) => block.id === right[index].id && sameSlice(block.slice, right[index].slice));
}
export function role(value: unknown): Role {
  if (value === "user" || value === "agent" || value === "system") return value;
  throw new Error(`Invalid packet role: ${String(value)}`);
}

function validateHead(head: Head) {
  if (!head || !Array.isArray(head.blocks)) throw new Error("Invalid thread head");
  const ids = new Set<string>();
  for (const block of head.blocks) {
    if (!block || typeof block.id !== "string" || !block.id) throw new Error("Invalid thread block");
    if (ids.has(block.id)) throw new Error(`Duplicate block id: ${block.id}`);
    ids.add(block.id); normalizeSlice(block.slice);
  }
}
function copyBlock(block: BlockRef): BlockRef { return { id: block.id, slice: { ...block.slice } }; }
function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
