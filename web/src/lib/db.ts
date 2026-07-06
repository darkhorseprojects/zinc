import { connect } from "@tursodatabase/database";
import crypto from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { defaultZincHome } from "./config";
import { decodeThreadBodyBytes, emptyThreadBody, encodeThreadBody, threadText, threadPacketIds, threadLabel } from "./threadBody";
import { editThreadBody } from "./editThreadBody";
import type { Thread, ThreadBody, ThreadView, Packet, ThreadListItem } from "./types";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const PACKET_OVERFLOW_MAGIC = "zinc-packet-overflow-v1\n";
const DEFAULT_PACKET_OVERFLOW_BYTES = 65536;

const SCHEMA = [
  `create table if not exists meta (
    key text primary key,
    value text not null
  )`,
  `create table if not exists packets (
    id text primary key,
    parent text,
    at integer not null,
    bytes blob not null
  )`,
  `create table if not exists threads (
    id text primary key,
    title text,
    body text not null,
    updated integer not null
  )`,
];

type Db = Awaited<ReturnType<typeof connect>>;

export class ConflictError extends Error {
  constructor(readonly current: string) {
    super("Thread changed before this edit could be saved.");
  }
}

export function newId(prefix: string) {
  return `${prefix}_${crypto.randomUUID()}`;
}

export function now() {
  return Math.floor(Date.now() / 1000);
}

export function resolveStorePath(storePath?: string | null) {
  return storePath || process.env.ZINC_STORE || join(defaultZincHome(), "zinc.db");
}

export async function openStore(storePath?: string | null) {
  const path = resolveStorePath(storePath);
  await mkdir(dirname(path), { recursive: true });
  const db = await connect(path);
  await ensureSchema(db);
  return db;
}

async function ensureSchema(db: Db) {
  for (const sql of SCHEMA) await (await db.prepare(sql)).run();
  await (await db.prepare("insert or replace into meta (key, value) values ('schema_version', '1')")).run();
}

export async function addPacket(
  db: Db,
  data: { parent?: string | null; bytes: string | Uint8Array },
  options: { packetOverflowBytes?: number } = {},
): Promise<Packet> {
  const id = newId("pkt");
  const at = now();
  const bytes = toBytes(data.bytes);
  const stored = await packetStoreBytes(id, bytes, options.packetOverflowBytes ?? DEFAULT_PACKET_OVERFLOW_BYTES);

  await (
    await db.prepare("insert into packets (id, parent, at, bytes) values (?, ?, ?, ?)")
  ).run(id, data.parent ?? null, at, stored);

  return { id, parent: data.parent ?? null, at, bytes };
}

export async function createThread(db: Db, metaOrName?: Record<string, any> | string): Promise<Thread> {
  const id = newId("thr");
  const updated = now();
  const title = typeof metaOrName === "string" ? metaOrName : typeof metaOrName?.name === "string" ? metaOrName.name : null;
  const body = emptyThreadBody();

  await (await db.prepare("insert into threads (id, title, body, updated) values (?, ?, ?, ?)")).run(
    id,
    title,
    threadBodyToJson(body),
    updated,
  );
  return { id, revision: revisionToken(updated), meta: title ? { name: title } : {} };
}

export async function updateThreadBodyFromPacket(db: Db, threadId: string, bodyPacketId: string) {
  const packet = await loadPacketFromDb(db, bodyPacketId);
  if (!packet) throw new Error(`Thread body packet not found: ${bodyPacketId}`);
  const body = decodeThreadBodyBytes(packet.bytes);
  if (!body) throw new Error(`Packet is not a thread body: ${bodyPacketId}`);
  await updateThreadBody(db, threadId, body);
}

async function updateThreadBody(db: Db, threadId: string, body: ThreadBody, title?: string | null) {
  const updated = now();
  if (title !== undefined) {
    await (await db.prepare("update threads set body = ?, title = ?, updated = ? where id = ?")).run(threadBodyToJson(body), title, updated, threadId);
  } else {
    await (await db.prepare("update threads set body = ?, updated = ? where id = ?")).run(threadBodyToJson(body), updated, threadId);
  }
}

export async function listThreads(storePath?: string | null): Promise<ThreadListItem[]> {
  const db = await openStore(storePath);
  try {
    const rows = await (await db.prepare("select id, title, body, updated from threads order by updated desc")).all();
    const threads: ThreadListItem[] = [];

    for (const row of rows as any[]) {
      const body = parseThreadBody(String(row.body));
      const packets = await loadThreadPackets(db, body);
      const title = row.title ? String(row.title) : threadLabel(body, packets);

      threads.push({
        id: String(row.id),
        label: title,
        revision: revisionToken(Number(row.updated)),
        updated: Number(row.updated),
        meta: title ? { name: title } : {},
      });
    }

    return threads;
  } finally {
    db.close();
  }
}

export async function createThread_(storePath?: string | null): Promise<ThreadView> {
  const db = await openStore(storePath);
  try {
    const thread = await createThread(db);
    return {
      id: thread.id,
      revision: thread.revision,
      updated: Number(thread.revision.slice(4)),
      body: emptyThreadBody(),
      packets: {},
      mdx: "",
      meta: thread.meta,
    };
  } finally {
    db.close();
  }
}

export async function loadThread(id: string, storePath?: string | null): Promise<ThreadView> {
  const db = await openStore(storePath);
  try {
    return await loadThreadFromDb(db, id);
  } finally {
    db.close();
  }
}

export async function deleteEmptyThread(id: string, storePath?: string | null): Promise<boolean> {
  const db = await openStore(storePath);
  try {
    const thread = await loadThreadFromDb(db, id).catch(() => null);
    if (!thread || thread.body.ranges.length > 0 || thread.mdx.trim()) return false;
    await (await db.prepare("delete from threads where id = ?")).run(id);
    return true;
  } finally {
    db.close();
  }
}

export async function loadThreadFromDb(db: Db, threadId: string): Promise<ThreadView> {
  const threadRow: any = await (await db.prepare("select id, title, body, updated from threads where id = ?")).get(threadId);
  if (!threadRow) throw new Error(`Thread not found: ${threadId}`);

  const updated = Number(threadRow.updated);
  const body = parseThreadBody(String(threadRow.body));
  const packets = await loadThreadPackets(db, body);
  const text = threadText(body, packets);
  const title = threadRow.title ? String(threadRow.title) : undefined;

  return {
    id: threadId,
    revision: revisionToken(updated),
    updated,
    body,
    packets,
    mdx: text.mdx,
    meta: title ? { name: title } : {},
  };
}

export async function commitThreadMdx(
  db: Db,
  threadId: string,
  baseRevision: string,
  mdx: string,
  options: { packetOverflowBytes?: number } = {},
): Promise<ThreadView> {
  const current = await loadThreadFromDb(db, threadId);
  if (current.revision !== baseRevision) throw new ConflictError(current.revision);

  const oldText = threadText(current.body, current.packets);
  if (oldText.mdx === mdx) return current;

  let parent: string | null = null;
  const nextBody = await editThreadBody(oldText, mdx, async (bytes) => {
    const packet = await addPacket(db, { parent, bytes }, options);
    parent = packet.id;
    return packet;
  });

  await updateThreadBody(db, threadId, nextBody);
  return await loadThreadFromDb(db, threadId);
}

export async function loadPacketFromDb(db: Db, id: string): Promise<Packet | null> {
  const row: any = await (await db.prepare("select id, parent, at, bytes from packets where id = ?")).get(id);
  if (!row) return null;

  return {
    id: String(row.id),
    parent: row.parent === null || row.parent === undefined ? null : String(row.parent),
    at: Number(row.at),
    bytes: await packetReadBytes(toBytes(row.bytes)),
  };
}

export async function loadStoredPacketBytesFromDb(db: Db, id: string): Promise<Uint8Array | null> {
  const row: any = await (await db.prepare("select bytes from packets where id = ?")).get(id);
  return row ? toBytes(row.bytes) : null;
}

export async function loadThreadPackets(db: Db, body: ThreadBody) {
  const packets: Record<string, Packet> = {};
  for (const id of threadPacketIds(body)) {
    const packet = await loadPacketFromDb(db, id);
    if (packet) packets[packet.id] = packet;
  }
  return packets;
}

async function packetStoreBytes(id: string, bytes: Uint8Array, packetOverflowBytes: number): Promise<Uint8Array> {
  if (packetOverflowBytes <= 0) throw new Error("packet-overflow-bytes must be positive");
  if (bytes.byteLength <= packetOverflowBytes && !startsWithOverflowMagic(bytes)) return bytes;

  const dir = join(tmpdir(), "zinc-packets");
  await mkdir(dir, { recursive: true });
  const path = join(dir, `${id}.packet`);
  await writeFile(path, bytes);
  const tail = bytes.slice(Math.max(0, bytes.byteLength - packetOverflowBytes));
  return encoder.encode(`${PACKET_OVERFLOW_MAGIC}${JSON.stringify({ path, size: bytes.byteLength, tail: Buffer.from(tail).toString("base64") })}\n`);
}

async function packetReadBytes(stored: Uint8Array): Promise<Uint8Array> {
  const overflow = decodePacketOverflow(stored);
  if (!overflow) return stored;
  const bytes = await readFile(overflow.path);
  if (bytes.byteLength !== overflow.size) throw new Error(`Packet overflow size mismatch: ${overflow.path}`);
  const tail = Buffer.from(overflow.tail, "base64");
  if (tail.byteLength && !Buffer.from(bytes).subarray(bytes.byteLength - tail.byteLength).equals(tail)) {
    throw new Error(`Packet overflow tail mismatch: ${overflow.path}`);
  }
  return bytes;
}

function decodePacketOverflow(stored: Uint8Array): { path: string; size: number; tail: string } | null {
  if (!startsWithOverflowMagic(stored)) return null;
  const text = decoder.decode(stored.slice(encoder.encode(PACKET_OVERFLOW_MAGIC).byteLength)).trim();
  const value = JSON.parse(text);
  if (!isRecord(value) || typeof value.path !== "string" || !Number.isInteger(value.size) || typeof value.tail !== "string") {
    throw new Error("Invalid packet overflow marker");
  }
  return { path: value.path, size: Number(value.size), tail: value.tail };
}

function startsWithOverflowMagic(bytes: Uint8Array) {
  const magic = encoder.encode(PACKET_OVERFLOW_MAGIC);
  if (bytes.byteLength < magic.byteLength) return false;
  for (let i = 0; i < magic.byteLength; i++) if (bytes[i] !== magic[i]) return false;
  return true;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function threadBodyToJson(body: ThreadBody) {
  return new TextDecoder().decode(encodeThreadBody(body)).trimEnd();
}

function parseThreadBody(value: string): ThreadBody {
  return decodeThreadBodyBytes(encoder.encode(value)) ?? emptyThreadBody();
}

function revisionToken(updated: number) {
  return `rev_${updated}`;
}

function toBytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return encoder.encode(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  return encoder.encode(String(value ?? ""));
}
