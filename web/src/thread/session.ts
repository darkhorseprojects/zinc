import { createSignal } from "solid-js";
import { markdownBlocks } from "../../../src/markdown-blocks";
import type { ZincClient } from "../client";
import { decodeBlock, markdownPacket } from "../editor/codec";
import type { BlockEditorHandle } from "../editor/BlockEditor";
import { identifierSuggestion, parseIdentifier } from "./identifier";
import type { BlockDescriptor, BlockPayload, BlockWrite, ThreadManifest, ZincEvent } from "./types";

type Dirty = { bytes: Uint8Array; origins: string[]; generation: number };
type Output = { reasoning: string; response: string; active: boolean; error: string };

export function createThreadSession(client: ZincClient, store: string, initial: ThreadManifest, options: { onCollapse?(thread: string): void; onManifest?(manifest: ThreadManifest): void } = {}) {
  const [manifest, setManifest] = createSignal(initial), [blocks, setBlocks] = createSignal(initial.blocks), [payloads, setPayloads] = createSignal(new Map<string, BlockPayload>()), [dirty, setDirty] = createSignal(new Map<string, Dirty>()), [identifier, setIdentifierValue] = createSignal(initial.identifier), [focused, setFocused] = createSignal<string | null>(null), [saving, setSaving] = createSignal(false), [conflicted, setConflicted] = createSignal(false), [output, setOutput] = createSignal<Output>({ reasoning: "", response: "", active: false, error: "" });
  const editors = new Map<string, BlockEditorHandle>(), queuedLoads = new Set<string>(), loading = new Set<string>(); let loadQueued = false, saveTimer: ReturnType<typeof setTimeout> | null = null, savePromise: Promise<ThreadManifest> | null = null, disposed = false;
  const unsubscribe = client.subscribe(handleEvent);

  function dispose() { if (disposed) return; disposed = true; unsubscribe(); if (saveTimer) clearTimeout(saveTimer); }
  function setPayload(id: string, value: BlockPayload) { setPayloads((current) => { const next = new Map(current); next.set(id, value); return next; }); }
  function removePayload(id: string) { setPayloads((current) => { const next = new Map(current); next.delete(id); return next; }); }
  function descriptor(id: string) { return blocks().find((block) => block.id === id); }
  function request(ids: string[]) { for (const id of ids) if (!payloads().has(id) && !loading.has(id) && descriptor(id)) queuedLoads.add(id); if (!queuedLoads.size || loadQueued) return; loadQueued = true; queueMicrotask(loadQueuedBlocks); }
  async function loadQueuedBlocks() { loadQueued = false; const ids = [...queuedLoads]; queuedLoads.clear(); if (!ids.length || disposed) return; ids.forEach((id) => loading.add(id)); try { for (const payload of await client.readBlocks(store, initial.id, manifest().revision, ids)) setPayload(payload.id, payload); } finally { ids.forEach((id) => loading.delete(id)); } }
  function bind(id: string, handle: BlockEditorHandle | null) { if (handle) editors.set(id, handle); else editors.delete(id); }
  function focus(id: string, edge: "start" | "end" = "end") { queueMicrotask(() => editors.get(id)?.focus(edge)); }
  function mark(id: string, bytes: Uint8Array, origins = [id]) { const generation = (dirty().get(id)?.generation ?? 0) + 1; setDirty((current) => { const next = new Map(current); next.set(id, { bytes, origins, generation }); return next; }); const payload = payloads().get(id); setPayload(id, { id, bytes, sources: payload?.sources ?? [] }); scheduleSave(); }
  function setFocus(id: string, value: boolean) { if (value) setFocused(id); else if (focused() === id) setFocused(null); }
  function scheduleSave() { if (conflicted()) return; if (saveTimer) clearTimeout(saveTimer); saveTimer = setTimeout(() => { saveTimer = null; void flush().catch(() => {}); }, 800); }
  function setIdentifier(value: string) { setIdentifierValue(parseIdentifier(value).value); scheduleSave(); }
  function reorder(order: string[]) { const map = new Map(blocks().map((block) => [block.id, block])); if (order.length !== map.size || order.some((id) => !map.has(id))) throw new Error("Invalid local block order"); setBlocks(order.map((id) => map.get(id)!)); scheduleSave(); }

  function split(id: string, before: string, after: string) {
    const index = blocks().findIndex((block) => block.id === id), current = blocks()[index]; if (index < 0 || !current) return;
    const nextId = fresh("blk"), nextDescriptor = { ...current, id: nextId, author: "draft", sourceCount: 1, byteLength: markdownPacket(after).byteLength };
    setBlocks((values) => [...values.slice(0, index), { ...current, byteLength: markdownPacket(before).byteLength }, nextDescriptor, ...values.slice(index + 1)]);
    mark(id, markdownPacket(before), [id]); mark(nextId, markdownPacket(after), [id]); focus(nextId, "start");
  }
  function merge(id: string, direction: "previous" | "next") {
    const values = blocks(), index = values.findIndex((block) => block.id === id), otherIndex = direction === "previous" ? index - 1 : index + 1; if (index < 0 || otherIndex < 0 || otherIndex >= values.length) return;
    const survivor = direction === "previous" ? values[otherIndex] : values[index], removed = direction === "previous" ? values[index] : values[otherIndex], left = direction === "previous" ? sourceOf(survivor.id) : sourceOf(id), right = direction === "previous" ? sourceOf(id) : sourceOf(removed.id); if (left === null || right === null) { request([survivor.id, removed.id]); return; }
    const joined = `${left}${left && right ? "\n\n" : ""}${right}`, origins = direction === "previous" ? [survivor.id, id] : [id, removed.id];
    setBlocks(values.filter((block) => block.id !== removed.id)); mark(survivor.id, markdownPacket(joined), origins); setDirty((current) => { const next = new Map(current); next.delete(removed.id); return next; }); removePayload(removed.id); focus(survivor.id, direction === "previous" ? "end" : "end");
  }
  function navigate(id: string, direction: "previous" | "next") { const values = blocks(), index = values.findIndex((block) => block.id === id), target = values[index + (direction === "previous" ? -1 : 1)]; if (!target) return; request([target.id]); focus(target.id, direction === "previous" ? "end" : "start"); }
  function sourceOf(id: string) { const bytes = dirty().get(id)?.bytes ?? payloads().get(id)?.bytes; if (!bytes) return null; const decoded = decodeBlock(bytes); if (decoded.format !== "markdown") return null; const value = JSON.parse(new TextDecoder().decode(bytes)); return typeof value.text === "string" ? value.text : null; }

  function patch(extra: Array<{ id: string; bytes: Uint8Array }> = [], identifierOverride?: string) {
    const writes: BlockWrite[] = [...dirty()].map(([id, value]) => ({ id, origins: value.origins, bytes: value.bytes }));
    for (const value of extra) writes.push({ id: value.id, origins: [], bytes: value.bytes });
    return { revision: manifest().revision, ...(identifierOverride !== undefined || identifier() !== manifest().identifier ? { identifier: identifierOverride ?? identifier() } : {}), order: [...blocks().map((block) => block.id), ...extra.map((block) => block.id)], writes };
  }

  async function flush(): Promise<ThreadManifest> {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    if (savePromise) { await savePromise; return flush(); }
    if (conflicted()) throw new Error("Thread changed elsewhere. Reload before saving.");
    if (!dirty().size && identifier() === manifest().identifier && sameOrder()) return manifest();
    const captured = new Map(dirty()), requestPatch = patch(); setSaving(true);
    savePromise = client.save(store, initial.id, requestPatch).then((result) => {
      if (result.collapsedTo) { options.onCollapse?.(result.collapsedTo); return result.manifest; }
      accept(result.manifest, captured); return result.manifest;
    }).catch((error) => { if ((error as { status?: number }).status === 409) setConflicted(true); throw error; }).finally(() => { setSaving(false); savePromise = null; });
    return savePromise;
  }
  function sameOrder() { const current = blocks(), saved = manifest().blocks; return current.length === saved.length && current.every((block, index) => block.id === saved[index].id); }
  function accept(next: ThreadManifest, captured: Map<string, Dirty>) {
    setManifest(next); setIdentifierValue(next.identifier); setBlocks((current) => {
      const server = new Map(next.blocks.map((block) => [block.id, block])); return next.blocks.map((block) => ({ ...block, ...(current.find((value) => value.id === block.id) && dirty().has(block.id) ? current.find((value) => value.id === block.id) : {}) }));
    });
    setDirty((current) => { const result = new Map(current); for (const [id, value] of captured) if (result.get(id)?.generation === value.generation) result.delete(id); return result; }); options.onManifest?.(next);
  }

  async function submit(markdown: string) {
    if (output().active || conflicted()) return;
    const packets = markdownBlocks(markdown).map((block) => block.raw.trimEnd()).filter(Boolean).map((text) => ({ id: fresh("blk"), bytes: markdownPacket(text) })); if (!packets.length) return;
    const proposed = identifier() || identifierSuggestion(markdown), requestPatch = patch(packets, proposed); setOutput({ reasoning: "", response: "", active: true, error: "" });
    const next = await client.complete(store, initial.id, requestPatch); for (const value of packets) setPayload(value.id, { id: value.id, bytes: value.bytes, sources: [] }); setManifest(next); setIdentifierValue(next.identifier); setBlocks(next.blocks); setDirty(new Map()); options.onManifest?.(next);
  }
  async function applySource(block: string, source: number) { await flush(); const result = await client.applySource(store, initial.id, manifest().revision, block, source); if (result.collapsedTo) options.onCollapse?.(result.collapsedTo); else { accept(result.manifest, new Map()); removePayload(block); request([block]); } }
  async function fork(block: string) { await flush(); return client.fork(store, initial.id, manifest().revision, block); }
  async function release() { await flush(); return client.release(store, initial.id); }
  async function refresh() { if (dirty().size) { setConflicted(true); return; } const next = await client.manifest(store, initial.id); setManifest(next); setIdentifierValue(next.identifier); setBlocks(next.blocks); options.onManifest?.(next); }
  function handleEvent(event: ZincEvent) {
    if (event.store !== store || event.thread !== initial.id) return;
    if (event.type === "reasoning" || event.type === "response") setOutput((value) => ({ ...value, active: true, [event.type]: value[event.type] + event.text }));
    else if (event.type === "error") setOutput((value) => ({ ...value, active: false, error: event.text }));
    else if (event.type === "done") { setOutput((value) => ({ ...value, active: false })); void refresh(); }
    else if (event.type === "deleted") { if (event.redirect) options.onCollapse?.(event.redirect); }
    else if (event.type === "update" && event.revision !== manifest().revision && !saving()) void refresh();
  }
  function pinned() { return new Set([...dirty().keys(), ...(focused() ? [focused()!] : [])]); }

  return { store, id: initial.id, manifest, blocks, payloads, dirty, identifier, focused, saving, conflicted, output, request, bind, focus, mark, setFocus, split, merge, navigate, reorder, setIdentifier, flush, submit, applySource, fork, release, refresh, pinned, dispose };
}
export type ThreadSession = ReturnType<typeof createThreadSession>;
function fresh(prefix: string) { return `${prefix}_${crypto.randomUUID()}`; }
