import { connect } from "@tursodatabase/database";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ConflictError, Store } from "../src/store.js";

const roots: string[] = [], encoder = new TextEncoder(), decoder = new TextDecoder();
afterEach(() => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));
async function fixture(limit = 64) { const root = await mkdtemp(join(tmpdir(), "zinc-store-")); roots.push(root); const path = join(root, "zinc.db"), packets = join(root, "packets"); return { root, path, packets, store: await Store.open({ path, packets, overflowBytes: limit }) }; }
const packet = (text: string, format = "markdown") => encoder.encode(`${JSON.stringify({ zinc: "text", format, text })}\n`);
async function add(store: Store, id: string, revision: string, text: string, block = "blk_a", author = "alice") { return store.commit(id, { revision, order: [block], writes: [{ id: block, origins: [], bytes: packet(text) }] }, author); }
async function text(store: Store, thread: string, revision: string, block: string) { const [value] = await store.readBlocks(thread, revision, [block]); return JSON.parse(decoder.decode(value.bytes)).text; }

describe("Store v8", () => {
  it("stores stable block identities, roles, authors, and exact lineage", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "hello");
    const second = await store.commit(created.id, { revision: first.manifest.revision, order: ["blk_a"], writes: [{ id: "blk_a", origins: ["blk_a"], bytes: packet("changed") }] }, "bob");
    expect(second.manifest.blocks[0]).toMatchObject({ id: "blk_a", role: "user", author: "bob", sourceCount: 1 });
    const [loaded] = await store.readBlocks(created.id, second.manifest.revision, ["blk_a"]); expect(JSON.parse(decoder.decode(loaded.bytes)).text).toBe("changed"); expect(loaded.sources).toHaveLength(1);
    await store.close();
  });

  it("saves order plus changed blocks and rejects stale patches", async () => {
    const { store } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("a") }, { id: "b", origins: [], bytes: packet("b") }] }, "alice");
    const moved = await store.commit(created.id, { revision: first.manifest.revision, order: ["b", "a"], writes: [] }, "alice"); expect(moved.manifest.blocks.map((block) => block.id)).toEqual(["b", "a"]);
    await expect(store.commit(created.id, { revision: first.manifest.revision, order: ["a"], writes: [] }, "alice")).rejects.toBeInstanceOf(ConflictError); await store.close();
  });

  it("keeps visual history complete while compacting context", async () => {
    const { store } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("one") }, { id: "b", origins: [], bytes: packet("two") }] }, "alice"), context = await store.slices(created.id, "context");
    await store.compact(created.id, context.revision, [{ action: "summarize", sources: context.blocks.map((block) => block.slice), rank: .5, bytes: packet("summary") }]);
    expect((await store.manifest(created.id)).blocks.map((block) => block.id)).toEqual(["a", "b"]); expect((await store.readContext(created.id)).parts).toHaveLength(1); expect((await store.state(created.id)).visualRevision).toBe(first.manifest.revision); await store.close();
  });

  it("preserves role when a human edits agent output and applies a source", async () => {
    const { store } = await fixture(), created = await store.create(); await store.appendMany(created.id, "agent", [packet("agent")]); const manifest = await store.manifest(created.id), id = manifest.blocks[0].id;
    const edited = await store.commit(created.id, { revision: manifest.revision, order: [id], writes: [{ id, origins: [id], bytes: packet("human edit") }] }, "alice"); expect(edited.manifest.blocks[0]).toMatchObject({ role: "agent", author: "alice" });
    const applied = await store.applySource(created.id, edited.manifest.revision, id, 0, "alice"); expect(applied.manifest.blocks[0].role).toBe("agent"); expect(await text(store, created.id, applied.manifest.revision, id)).toBe("agent"); await store.close();
  });

  it("creates a prefix fork without copying a head and exposes every member", async () => {
    const { store, path } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("a") }, { id: "b", origins: [], bytes: packet("b") }] }, "alice"), fork = await store.fork(created.id, first.manifest.revision, "a");
    expect(fork.manifest.blocks.map((block) => block.id)).toEqual(["a"]); const parent = await store.manifest(created.id); expect(parent.forkPoints[0].members.map((member) => member.id).sort()).toEqual([created.id, fork.id].sort());
    const db = await connect(path), rows: any[] = await (await db.prepare("select body_packet,body_to,baseline_packet from threads where id in (?,?) order by id")).all(created.id, fork.id); expect(new Set(rows.map((row) => row.body_packet)).size).toBe(1); expect(rows.find((row) => row.body_to)?.baseline_packet).toBe(rows.find((row) => row.body_to)?.body_packet); await db.close(); await store.close();
  });

  it("collapses a divergent fork when it returns exactly to baseline", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "base", "a"), fork = await store.fork(created.id, first.manifest.revision, "a");
    const diverged = await store.commit(fork.id, { revision: fork.manifest.revision, order: ["a", "x"], writes: [{ id: "x", origins: [], bytes: packet("branch") }] }, "alice");
    const collapsed = await store.commit(fork.id, { revision: diverged.manifest.revision, order: ["a"], writes: [] }, "alice"); expect(collapsed.collapsedTo).toBe(created.id); await expect(store.manifest(fork.id)).rejects.toThrow(/not found/); await store.close();
  });

  it("records prompt usage and resets only context on compaction", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "one"), state = await store.state(created.id); await store.recordPromptTokens(created.id, state.contextRevision, 123); const context = await store.slices(created.id, "context"); await store.compact(created.id, context.revision, context.blocks.map((block) => ({ action: "keep" as const, sources: [block.slice], rank: 1 }))); expect((await store.state(created.id)).promptTokens).toBe(0); expect((await store.manifest(created.id)).revision).toBe(first.manifest.revision); await store.close();
  });

  it("supports validated overflow payloads", async () => { const { store, packets } = await fixture(2), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "long payload"); expect(await text(store, created.id, first.manifest.revision, "blk_a")).toBe("long payload"); expect((await readdir(packets)).some((file) => file.endsWith(".packet"))).toBe(true); await store.close(); });

  it("rejects old stores without migration", async () => { const root = await mkdtemp(join(tmpdir(), "zinc-v7-")); roots.push(root); const path = join(root, "zinc.db"), db = await connect(path); await db.run("create table meta(key text primary key,value text not null)"); await db.run("insert into meta values('schema_version','7')"); await db.close(); await expect(Store.open({ path, packets: join(root, "packets"), overflowBytes: 64 })).rejects.toThrow("Unsupported Zinc store schema: 7"); });
});
