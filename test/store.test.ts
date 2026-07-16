import assert from "node:assert/strict";
import { connect } from "@tursodatabase/database";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, it } from "node:test";
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
    assert.deepEqual({ ...second.manifest.blocks[0] }, { id: "blk_a", role: "user", author: "bob", sourceCount: 1, byteLength: packet("changed").byteLength });
    assert.deepEqual({ ...second.acknowledged[0], sources: undefined }, { id: "blk_a", role: "user", author: "bob", sources: undefined });
    assert.equal(second.acknowledged[0].sources.length, 1);
    const [loaded] = await store.readBlocks(created.id, second.manifest.revision, ["blk_a"]);
    assert.equal(JSON.parse(decoder.decode(loaded.bytes)).text, "changed");
    assert.equal(loaded.sources.length, 1);
    await store.close();
  });

  it("saves order plus changed blocks and rejects stale patches", async () => {
    const { store } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("a") }, { id: "b", origins: [], bytes: packet("b") }] }, "alice");
    const moved = await store.commit(created.id, { revision: first.manifest.revision, order: ["b", "a"], writes: [] }, "alice");
    assert.deepEqual(moved.manifest.blocks.map((block) => block.id), ["b", "a"]);
    await assert.rejects(store.commit(created.id, { revision: first.manifest.revision, order: ["a"], writes: [] }, "alice"), ConflictError);
    await store.close();
  });

  it("keeps visual history complete while compacting context", async () => {
    const { store } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("one") }, { id: "b", origins: [], bytes: packet("two") }] }, "alice"), context = await store.slices(created.id, "context");
    await store.compact(created.id, context.revision, [{ action: "summarize", sources: context.blocks.map((block) => block.slice), rank: .5, bytes: packet("summary") }]);
    assert.deepEqual((await store.manifest(created.id)).blocks.map((block) => block.id), ["a", "b"]);
    assert.equal((await store.readContext(created.id)).parts.length, 1);
    assert.equal((await store.state(created.id)).visualRevision, first.manifest.revision);
    await store.close();
  });

  it("preserves role when a human edits agent output and applies a source", async () => {
    const { store } = await fixture(), created = await store.create();
    await store.appendMany(created.id, "agent", [packet("agent")]);
    const manifest = await store.manifest(created.id), id = manifest.blocks[0].id;
    const edited = await store.commit(created.id, { revision: manifest.revision, order: [id], writes: [{ id, origins: [id], bytes: packet("human edit") }] }, "alice");
    assert.equal(edited.manifest.blocks[0].role, "agent");
    assert.equal(edited.manifest.blocks[0].author, "alice");
    const applied = await store.applySource(created.id, edited.manifest.revision, id, 0, "alice");
    assert.equal(applied.manifest.blocks[0].role, "agent");
    assert.equal(await text(store, created.id, applied.manifest.revision, id), "agent");
    await store.close();
  });

  it("creates a prefix fork without copying a head and exposes every member", async () => {
    const { store, path } = await fixture(), created = await store.create(), first = await store.commit(created.id, { revision: created.manifest.revision, order: ["a", "b"], writes: [{ id: "a", origins: [], bytes: packet("a") }, { id: "b", origins: [], bytes: packet("b") }] }, "alice"), fork = await store.fork(created.id, first.manifest.revision, "a");
    assert.deepEqual(fork.manifest.blocks.map((block) => block.id), ["a"]);
    const parent = await store.manifest(created.id);
    assert.deepEqual(parent.forkPoints[0].members.map((member) => member.id).sort(), [created.id, fork.id].sort());
    const db = await connect(path), rows: any[] = await (await db.prepare("select body_packet,body_to,baseline_packet from threads where id in (?,?) order by id")).all(created.id, fork.id);
    assert.equal(new Set(rows.map((row) => row.body_packet)).size, 1);
    assert.equal(rows.find((row) => row.body_to)?.baseline_packet, rows.find((row) => row.body_to)?.body_packet);
    await db.close();
    await store.close();
  });

  it("keeps a baseline fork through listing and collapses it only on release", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "base", "a"), fork = await store.fork(created.id, first.manifest.revision, "a");
    assert.ok((await store.list()).some((thread) => thread.id === fork.id));
    assert.equal((await store.manifest(fork.id)).id, fork.id);
    assert.equal((await store.release(fork.id)).collapsedTo, created.id);
    await assert.rejects(store.manifest(fork.id), /not found/);
    await store.close();
  });

  it("collapses a divergent fork when it returns exactly to baseline", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "base", "a"), fork = await store.fork(created.id, first.manifest.revision, "a");
    const diverged = await store.commit(fork.id, { revision: fork.manifest.revision, order: ["a", "x"], writes: [{ id: "x", origins: [], bytes: packet("branch") }] }, "alice");
    const collapsed = await store.commit(fork.id, { revision: diverged.manifest.revision, order: ["a"], writes: [] }, "alice");
    assert.equal(collapsed.collapsedTo, created.id);
    await assert.rejects(store.manifest(fork.id), /not found/);
    await store.close();
  });

  it("records prompt usage and resets only context on compaction", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "one"), state = await store.state(created.id);
    await store.recordPromptTokens(created.id, state.contextRevision, 123);
    const context = await store.slices(created.id, "context");
    await store.compact(created.id, context.revision, context.blocks.map((block) => ({ action: "keep" as const, sources: [block.slice], rank: 1 })));
    assert.equal((await store.state(created.id)).promptTokens, 0);
    assert.equal((await store.manifest(created.id)).revision, first.manifest.revision);
    await store.close();
  });

  it("supports validated overflow payloads", async () => {
    const { store, packets } = await fixture(2), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "long payload");
    assert.equal(await text(store, created.id, first.manifest.revision, "blk_a"), "long payload");
    assert.ok((await readdir(packets)).some((file) => file.endsWith(".packet")));
    await store.close();
  });

  it("builds manifests from packet metadata without opening block overflow files", async () => {
    const { store, packets } = await fixture(256), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "x".repeat(2048));
    const overflow = (await readdir(packets)).filter((file) => file.endsWith(".packet")); assert.equal(overflow.length, 1); await rm(join(packets, overflow[0]));
    assert.equal((await store.manifest(created.id)).blocks[0].byteLength, packet("x".repeat(2048)).byteLength);
    await assert.rejects(store.readBlocks(created.id, first.manifest.revision, ["blk_a"]), /ENOENT/);
    await store.close();
  });

  it("derives uncached automatic titles in a batched listing without persisting them", async () => {
    const { store } = await fixture(), created = await store.create(), first = await add(store, created.id, created.manifest.revision, "# First meaningful user message with extra words");
    const [summary] = await store.list(); assert.equal(summary.identifier, ""); assert.equal(summary.title, "First meaningful user message with extra words");
    assert.equal((await store.manifest(created.id)).title, summary.title);
    const heads = await store.readHeads(created.id); assert.equal(heads.visual.revision, first.manifest.revision); assert.deepEqual(heads.visual.parts.map((part) => part.id), heads.context.parts.map((part) => part.id));
    await store.close();
  });

  it("rejects old stores without migration", async () => {
    const root = await mkdtemp(join(tmpdir(), "zinc-v7-")); roots.push(root); const path = join(root, "zinc.db"), db = await connect(path);
    await db.run("create table meta(key text primary key,value text not null)");
    await db.run("insert into meta values('schema_version','7')");
    await db.close();
    await assert.rejects(Store.open({ path, packets: join(root, "packets"), overflowBytes: 64 }), /Unsupported Zinc store schema: 7/);
  });
});
