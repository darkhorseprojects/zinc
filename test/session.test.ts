import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { ZincClient } from "../web/src/client.js";
import { markdownPacket } from "../web/src/editor/codec.js";
import { createThreadSession } from "../web/src/thread/session.js";
import type { CommitResult, ThreadManifest, ThreadPatch, ZincEvent } from "../web/src/thread/types.js";

const block = (id: string, byteLength = 1) => ({ id, role: "user" as const, author: "alice", sourceCount: 0, byteLength });
const manifest = (revision: string, ids = ["a", "b"], identifier = "#old Old"): ThreadManifest => ({ id: "thr_test", revision, updated: 1, identifier, title: identifier || "Automatic title", blocks: ids.map((id) => block(id)), forkPoints: [] });

class FakeClient {
  listeners = new Set<(event: ZincEvent) => void>();
  saves: ThreadPatch[] = [];
  manifests = 0;
  reads = 0;
  sourceReads: string[] = [];
  blockSources: Array<{ packet: string; from?: number; to?: number }> = [];
  pending: ReturnType<typeof deferred<CommitResult>>[] = [];
  current = manifest("rev_1");
  subscribe(listener: (event: ZincEvent) => void) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  emit(event: ZincEvent) { for (const listener of this.listeners) listener(event); }
  save(_store: string, _thread: string, patch: ThreadPatch) { this.saves.push(patch); const request = deferred<CommitResult>(); this.pending.push(request); return request.promise; }
  async manifest() { this.manifests++; return this.current; }
  async readBlocks(_store: string, _thread: string, _revision: string, ids: string[]) { this.reads++; return ids.map((id) => ({ id, bytes: markdownPacket(id), sources: this.blockSources })); }
  async readSource(_store: string, source: { packet: string }) { this.sourceReads.push(source.packet); return markdownPacket(source.packet); }
  async applySource() { return { manifest: this.current }; }
  async fork() { return { id: "thr_fork", manifest: this.current }; }
  async release() { return undefined; }
  async delete() { return true; }
  complete() { throw new Error("not implemented"); }
}

describe("thread session save generations", () => {
  it("preserves newer identifier and order while accepting an older save", async () => {
    const client = new FakeClient(), session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.setIdentifier("#first First"); session.reorder(["b", "a"]);
    const saving = session.flush(); await tick();
    assert.equal(session.status(), "saving");
    session.setIdentifier("#second Second"); session.reorder(["a", "b"]);
    const saved = manifest("rev_2", ["b", "a"], "#first First"); client.current = saved; client.pending[0].resolve({ manifest: saved, acknowledged: [] }); await saving;
    assert.equal(session.identifier(), "#second Second");
    assert.deepEqual(session.blocks().map((value) => value.id), ["a", "b"]);
    assert.equal(session.status(), "dirty");
    session.dispose();
  });

  it("preserves a split made while a content save is in flight", async () => {
    const client = new FakeClient(), session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.mark("a", markdownPacket("edited")); const saving = session.flush(); await tick();
    session.split("b", "before", "after"); const inserted = session.blocks().find((value) => !["a", "b"].includes(value.id)); assert.ok(inserted);
    const saved = manifest("rev_2"); client.current = saved; client.pending[0].resolve({ manifest: saved, acknowledged: [{ id: "a", role: "user", author: "alice", sources: [] }] }); await saving;
    assert.ok(session.blocks().some((value) => value.id === inserted.id));
    assert.ok(session.dirty().has(inserted.id));
    assert.equal(session.status(), "dirty");
    session.dispose();
  });

  it("invalidates clean payloads when a stable block changes remotely", async () => {
    const client = new FakeClient(), session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.request(["a"]); await tick(); await tick();
    assert.equal(session.payloads().has("a"), true);
    client.current = manifest("rev_2"); client.emit({ type: "update", store: "/store", thread: "thr_test", revision: "rev_2" }); await tick(); await tick();
    assert.equal(session.manifest().revision, "rev_2");
    assert.equal(session.payloads().has("a"), false);
    session.dispose();
  });

  it("freezes dirty sessions on remote conflict and reports it once", async () => {
    const client = new FakeClient(); let conflicts = 0;
    const session = createThreadSession(client as unknown as ZincClient, "/store", client.current, { onConflict: () => conflicts++ });
    session.mark("a", markdownPacket("local"));
    client.emit({ type: "update", store: "/store", thread: "thr_test", revision: "rev_2" });
    client.emit({ type: "update", store: "/store", thread: "thr_test", revision: "rev_3" }); await tick();
    assert.equal(session.conflicted(), true);
    assert.equal(conflicts, 1);
    await assert.rejects(session.flush(), /Reload before saving/);
    assert.equal(session.dirty().has("a"), true);
    session.dispose();
  });

  it("accepts written metadata without reading the saved block back", async () => {
    const client = new FakeClient(), session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.request(["a"]); await tick(); await tick(); assert.equal(client.reads, 1);
    const edited = markdownPacket("edited"); session.mark("a", edited); const saving = session.flush(); await tick();
    const saved = manifest("rev_2"); client.current = saved; client.pending[0].resolve({ manifest: saved, acknowledged: [{ id: "a", role: "user", author: "alice", sources: [{ packet: "pkt_old" }] }] }); await saving; await tick();
    assert.equal(client.reads, 1); assert.deepEqual(session.payloads().get("a")?.bytes, edited); assert.equal(session.payloads().get("a")?.sources[0].packet, "pkt_old"); session.dispose();
  });

  it("loads and caches only the interacted provenance source", async () => {
    const client = new FakeClient(); client.blockSources = [{ packet: "pkt_one" }, { packet: "pkt_two" }];
    const session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.request(["a"]); await tick(); await tick();
    assert.deepEqual(client.sourceReads, []);
    const first = await session.resolveSource("a", 1); const cached = await session.resolveSource("a", 1);
    assert.deepEqual(first, cached); assert.deepEqual(client.sourceReads, ["pkt_two"]);
    await session.resolveSource("a", 0); assert.deepEqual(client.sourceReads, ["pkt_two", "pkt_one"]);
    session.dispose();
  });

  it("does not treat its own early SSE update as an external conflict", async () => {
    const client = new FakeClient(), session = createThreadSession(client as unknown as ZincClient, "/store", client.current);
    session.setIdentifier("Saved"); const saving = session.flush(); await tick();
    client.emit({ type: "update", store: "/store", thread: "thr_test", revision: "rev_2" });
    const saved = manifest("rev_2", ["a", "b"], "Saved"); client.current = saved; client.pending[0].resolve({ manifest: saved, acknowledged: [] }); await saving; await tick();
    assert.equal(session.conflicted(), false);
    assert.equal(client.manifests, 0);
    assert.equal(session.status(), "clean");
    session.dispose();
  });
});

function deferred<T>() { let resolve!: (value: T) => void, reject!: (reason?: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function tick() { return new Promise((resolve) => setTimeout(resolve, 0)); }
