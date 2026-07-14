import type { BlockPayload, Bootstrap, CommitResult, StoreRef, ThreadManifest, ThreadPatch, ThreadSummary, ZincEvent } from "./thread/types";

type Listener = (event: ZincEvent) => void;

export class ZincClient {
  private listeners = new Set<Listener>();
  private source: EventSource | null = null;

  async bootstrap(store?: string | null, thread?: string | null): Promise<Bootstrap> {
    const query = new URLSearchParams(); if (store) query.set("store", store); if (thread) query.set("thread", thread);
    const value = await this.request(`/api/bootstrap${query.size ? `?${query}` : ""}`);
    if (!record(value)) throw new Error("Invalid bootstrap");
    return {
      stores: array(value.stores).filter(storeRef), store: typeof value.store === "string" ? value.store : null, threads: array(value.threads).map(summary), thread: typeof value.thread === "string" ? value.thread : null,
      manifest: value.manifest ? manifest(value.manifest) : null, author: typeof value.author === "string" ? value.author : "anonymous", rawContextBytes: Number(value.rawContextBytes) || 8192,
    };
  }
  async stores() { const value = await this.request("/api/stores"); return record(value) ? array(value.stores).filter(storeRef) : []; }
  async addStore(path: string, name?: string) { const value = await this.request("/api/stores", post({ path, name })); return record(value) ? array(value.stores).filter(storeRef) : []; }
  async threads(store: string) { const value = await this.request(`/api/threads?store=${encodeURIComponent(store)}`); return record(value) ? array(value.threads).map(summary) : []; }
  async create(store: string) { const value = await this.request("/api/threads", post({ store })); if (!record(value) || typeof value.id !== "string") throw new Error("Invalid created thread"); return { id: value.id, manifest: manifest(value.manifest) }; }
  async manifest(store: string, thread: string) { return manifest(await this.request(`/api/thread?store=${encodeURIComponent(store)}&thread=${encodeURIComponent(thread)}`)); }
  async readBlocks(store: string, thread: string, revision: string, ids: string[]): Promise<BlockPayload[]> { const value = await this.request("/api/blocks/read", post({ store, thread, revision, ids })); if (!record(value)) throw new Error("Invalid block read"); return array(value.blocks).map(payload); }
  async save(store: string, thread: string, patch: ThreadPatch): Promise<CommitResult> { return commit(await this.request("/api/thread", post({ store, thread, patch: wirePatch(patch) }))); }
  async readSource(store: string, source: { packet: string; from?: number; to?: number }) { const query = new URLSearchParams({ store, packet: source.packet }); if (source.from !== undefined) query.set("from", String(source.from)); if (source.to !== undefined) query.set("to", String(source.to)); const response = await fetch(`/api/source?${query}`); if (!response.ok) throw new Error(await responseError(response)); return new Uint8Array(await response.arrayBuffer()); }
  async applySource(store: string, thread: string, revision: string, block: string, source: number) { return commit(await this.request("/api/source", post({ store, thread, revision, block, source }))); }
  async fork(store: string, thread: string, revision: string, block: string) { const value = await this.request("/api/fork", post({ store, thread, revision, block })); if (!record(value) || typeof value.id !== "string") throw new Error("Invalid fork"); return { id: value.id, manifest: manifest(value.manifest) }; }
  async release(store: string, thread: string) { const value = await this.request("/api/thread/release", post({ store, thread })); return record(value) && typeof value.collapsedTo === "string" ? value.collapsedTo : undefined; }
  async delete(store: string, thread: string) { const value = await this.request(`/api/thread?store=${encodeURIComponent(store)}&thread=${encodeURIComponent(thread)}`, { method: "DELETE" }); return record(value) && value.deleted === true; }
  async complete(store: string, thread: string, patch: ThreadPatch) { const value = await this.request("/api/completions", post({ store, thread, patch: wirePatch(patch) })); if (!record(value) || value.started !== true) throw new Error("Completion did not start"); return manifest(value.manifest); }
  async cancel(store: string, thread: string) { const value = await this.request("/api/completions", { method: "DELETE", headers: { "content-type": "application/json" }, body: JSON.stringify({ store, thread }) }); return record(value) && value.cancelled === true; }
  subscribe(listener: Listener) { this.listeners.add(listener); this.connect(); return () => this.listeners.delete(listener); }
  close() { this.source?.close(); this.source = null; this.listeners.clear(); }
  private connect() { if (this.source || typeof EventSource === "undefined") return; this.source = new EventSource("/api/events"); this.source.onmessage = ({ data }) => { const event = JSON.parse(data) as ZincEvent; for (const listener of this.listeners) listener(event); }; }
  private async request(path: string, init: RequestInit = {}) { const response = await fetch(path, init), value = await response.json().catch(() => null); if (!response.ok) throw Object.assign(new Error(record(value) && typeof value.error === "string" ? value.error : `Request failed: ${response.status}`), { status: response.status, current: record(value) ? value.current : undefined }); return value; }
}
function wirePatch(patch: ThreadPatch) { return { ...patch, writes: patch.writes.map((write) => ({ ...write, bytes: toBase64(write.bytes) })) }; }
function manifest(value: unknown): ThreadManifest { if (!record(value) || typeof value.id !== "string" || typeof value.revision !== "string" || typeof value.identifier !== "string") throw new Error("Invalid thread manifest"); return { id: value.id, revision: value.revision, identifier: value.identifier, blocks: array(value.blocks).map((block) => { if (!record(block)) throw new Error("Invalid block descriptor"); return { id: String(block.id), role: role(block.role), author: String(block.author), sourceCount: Number(block.sourceCount), byteLength: Number(block.byteLength) }; }), forkPoints: array(value.forkPoints).map((point) => { if (!record(point)) throw new Error("Invalid fork point"); return { id: String(point.id), block: String(point.block), members: array(point.members).map(summary) }; }) }; }
function payload(value: unknown): BlockPayload { if (!record(value) || typeof value.id !== "string" || typeof value.bytes !== "string") throw new Error("Invalid block payload"); return { id: value.id, bytes: fromBase64(value.bytes), sources: array(value.sources).map((source) => { if (!record(source) || typeof source.packet !== "string") throw new Error("Invalid source"); return { packet: source.packet, ...(Number.isInteger(source.from) ? { from: Number(source.from) } : {}), ...(Number.isInteger(source.to) ? { to: Number(source.to) } : {}) }; }) }; }
function commit(value: unknown): CommitResult { if (!record(value)) throw new Error("Invalid commit"); return { manifest: manifest(value.manifest), ...(typeof value.collapsedTo === "string" ? { collapsedTo: value.collapsedTo } : {}) }; }
function summary(value: unknown): ThreadSummary { if (!record(value)) throw new Error("Invalid thread summary"); return { id: String(value.id), identifier: String(value.identifier ?? ""), revision: String(value.revision), updated: Number(value.updated) }; }
function role(value: unknown) { if (value === "user" || value === "agent" || value === "system") return value; throw new Error("Invalid role"); }
function storeRef(value: unknown): value is StoreRef { return record(value) && typeof value.path === "string" && typeof value.name === "string"; }
function post(value: unknown): RequestInit { return { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(value) }; }
function fromBase64(value: string) { return Uint8Array.from(atob(value), (character) => character.charCodeAt(0)); }
function toBase64(value: Uint8Array) { let result = ""; for (const byte of value) result += String.fromCharCode(byte); return btoa(result); }
function array(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
async function responseError(response: Response) { const value = await response.json().catch(() => null); return record(value) && typeof value.error === "string" ? value.error : `Request failed: ${response.status}`; }
export const zincClient = new ZincClient();
