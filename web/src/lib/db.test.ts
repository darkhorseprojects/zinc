import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { addPacket, commitThreadMdx, createThread_, deleteEmptyThread, loadThread, openStore, loadPacketFromDb, loadStoredPacketBytesFromDb } from "./db";

const stores: string[] = [];
const decoder = new TextDecoder();

async function tempStore() {
  const dir = await mkdtemp(join(tmpdir(), "zinc-web-test"));
  stores.push(dir);
  return join(dir, "zinc.db");
}

afterEach(async () => {
  await Promise.all(stores.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("Zinc thread store", () => {
  it("creates and loads an empty thread body", async () => {
    const store = await tempStore();
    const created = await createThread_(store);
    const loaded = await loadThread(created.id, store);

    expect(loaded.id).toMatch(/^thr_/);
    expect(loaded.revision).toMatch(/^rev_/);
    expect(loaded.body).toEqual({ ranges: [] });
    expect(loaded.packets).toEqual({});
    expect(loaded.mdx).toBe("");
  });

  it("deletes only empty abandoned threads", async () => {
    const store = await tempStore();
    const empty = await createThread_(store);

    expect(await deleteEmptyThread(empty.id, store)).toBe(true);
    await expect(loadThread(empty.id, store)).rejects.toThrow(/Thread not found/);

    const nonEmpty = await createThread_(store);
    const db = await openStore(store);
    try {
      await commitThreadMdx(db, nonEmpty.id, nonEmpty.revision, "hello");
    } finally {
      db.close();
    }

    expect(await deleteEmptyThread(nonEmpty.id, store)).toBe(false);
    expect((await loadThread(nonEmpty.id, store)).mdx).toBe("hello");
  });

  it("does not change revision for unchanged mdx", async () => {
    const store = await tempStore();
    const thread = await createThread_(store);
    const db = await openStore(store);
    try {
      const first = await commitThreadMdx(db, thread.id, thread.revision, "hello");
      const second = await commitThreadMdx(db, thread.id, first.revision, "hello");

      expect(second.revision).toBe(first.revision);
      expect(second.mdx).toBe("hello");
    } finally {
      db.close();
    }
  });

  it("stores immutable packet bytes", async () => {
    const store = await tempStore();
    const db = await openStore(store);
    try {
      const first = await addPacket(db, { bytes: "hello" });
      const second = await addPacket(db, { bytes: "world" });

      expect(decoder.decode(first.bytes)).toBe("hello");
      expect(decoder.decode(second.bytes)).toBe("world");

      const loadedFirst = await loadPacketFromDb(db, first.id);
      expect(loadedFirst).not.toBeNull();
      expect(decoder.decode(loadedFirst!.bytes)).toBe("hello");
    } finally {
      db.close();
    }
  });

  it("stores oversized packet bytes outside the database and loads exact bytes", async () => {
    const store = await tempStore();
    const db = await openStore(store);
    try {
      const data = "1234567890".repeat(100);
      const packet = await addPacket(db, { bytes: data }, { packetOverflowBytes: 64 });
      const stored = await loadStoredPacketBytesFromDb(db, packet.id);
      const loaded = await loadPacketFromDb(db, packet.id);

      expect(stored).not.toBeNull();
      expect(decoder.decode(stored!)).toContain("zinc-packet-overflow-v1");
      expect(decoder.decode(stored!)).toContain(Buffer.from(data.slice(-64)).toString("base64"));
      expect(decoder.decode(stored!)).not.toContain(data);
      expect(loaded).not.toBeNull();
      expect(decoder.decode(loaded!.bytes)).toBe(data);
    } finally {
      db.close();
    }
  });

  it("uses packets threads and meta tables only", async () => {
    const store = await tempStore();
    const db = await openStore(store);
    try {
      const rows = await (await db.prepare("select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name")).all();
      expect((rows as any[]).map((row) => row.name)).toEqual(["meta", "packets", "threads"]);

      const packetColumns = await (await db.prepare("pragma table_info(packets)")).all();
      expect((packetColumns as any[]).map((row) => row.name)).toEqual(["id", "parent", "at", "bytes"]);

      const threadColumns = await (await db.prepare("pragma table_info(threads)")).all();
      expect((threadColumns as any[]).map((row) => row.name)).toEqual(["id", "title", "body", "updated"]);
    } finally {
      db.close();
    }
  });
});
