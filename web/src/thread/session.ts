import { createSignal } from "solid-js";
import { markdownBlocks } from "../../../src/markdown-blocks";
import type { ZincClient } from "../client";
import { decodeBlock, markdownPacket } from "../editor/codec";
import type { BlockEditorHandle } from "../editor/BlockEditor";
import { parseIdentifier } from "./identifier";
import type { BlockAcknowledgement, BlockDescriptor, BlockPayload, BlockWrite, ThreadManifest, ZincEvent } from "./types";

type Dirty = { bytes: Uint8Array; origins: string[]; generation: number };
type Output = { reasoning: string; response: string; active: boolean; error: string };
type SaveStatus = "clean" | "dirty" | "saving";
type Snapshot = { dirty: Map<string, Dirty>; order: string[]; orderGeneration: number; identifier: string; identifierGeneration: number };
type Options = { onCollapse?(thread: string): void; onManifest?(manifest: ThreadManifest): void; onError?(title: string, error: unknown): void; onConflict?(): void };
const PAYLOAD_LIMIT = 64;

export function createThreadSession(client: ZincClient, store: string, initial: ThreadManifest, options: Options = {}) {
  const [manifest, setManifest] = createSignal(initial), [blocks, setBlocks] = createSignal(initial.blocks), [payloads, setPayloads] = createSignal(new Map<string, BlockPayload>()), [dirty, setDirty] = createSignal(new Map<string, Dirty>()), [identifier, setIdentifierValue] = createSignal(initial.identifier), [focused, setFocused] = createSignal<string | null>(null), [saving, setSaving] = createSignal(false), [conflicted, setConflicted] = createSignal(false), [output, setOutput] = createSignal<Output>({ reasoning: "", response: "", active: false, error: "" }), [loadErrors, setLoadErrors] = createSignal(new Set<string>());
  const editors = new Map<string, BlockEditorHandle>(), queuedLoads = new Map<string, boolean>(), loading = new Set<string>(), recent = new Map<string, number>(), sourceLoads = new Map<string, Promise<Uint8Array>>();
  let generation = 0, orderGeneration = 0, identifierGeneration = 0, access = 0, loadQueued = false, saveTimer: ReturnType<typeof setTimeout> | null = null, mutation = Promise.resolve(), mutating = false, disposed = false, conflictNotified = false;
  const pendingEvents: ZincEvent[] = [], unsubscribe = client.subscribe(handleEvent);

  function changed() { return dirty().size > 0 || identifier() !== manifest().identifier || !sameOrder(blocks(), manifest().blocks); }
  function status(): SaveStatus { return saving() ? "saving" : changed() ? "dirty" : "clean"; }
  function locked() { return output().active; }
  function dispose() { if (disposed) return; disposed = true; unsubscribe(); if (saveTimer) clearTimeout(saveTimer); }
  function touch(ids: string[]) { for (const id of ids) recent.set(id, ++access); }
  function setPayload(id: string, value: BlockPayload) { touch([id]); setPayloads((current) => { const next = new Map(current); next.set(id, value); return trim(next); }); }
  function removePayload(id: string) { recent.delete(id); setPayloads((current) => { const next = new Map(current); next.delete(id); return next; }); }
  function retain(ids: string[]) { touch(ids); setPayloads((current) => trim(new Map(current), new Set(ids))); }
  function trim(values: Map<string, BlockPayload>, visible = new Set<string>()) { const protectedIds = new Set([...visible, ...dirty().keys(), ...(focused() ? [focused()!] : [])]); if (values.size <= PAYLOAD_LIMIT) return values; const removable = [...values.keys()].filter((id) => !protectedIds.has(id)).sort((left, right) => (recent.get(left) ?? 0) - (recent.get(right) ?? 0)); while (values.size > PAYLOAD_LIMIT && removable.length) { const id = removable.shift()!; values.delete(id); recent.delete(id); } return values; }
  function descriptor(id: string) { return blocks().find((block) => block.id === id); }

  function request(ids: string[], force = false) {
    touch(ids);
    for (const id of ids) if (descriptor(id) && !loading.has(id) && (force || !payloads().has(id))) queuedLoads.set(id, force || queuedLoads.get(id) === true);
    if (!queuedLoads.size || loadQueued) return;
    loadQueued = true; queueMicrotask(loadQueuedBlocks);
  }
  async function loadQueuedBlocks() {
    loadQueued = false; const entries = [...queuedLoads]; queuedLoads.clear(); if (!entries.length || disposed) return;
    const revision = manifest().revision, ids = entries.map(([id]) => id); ids.forEach((id) => loading.add(id));
    try {
      const values = await client.readBlocks(store, initial.id, revision, ids);
      if (disposed || manifest().revision !== revision) { for (const [id, force] of entries) queuedLoads.set(id, force); return queueMicrotask(loadQueuedBlocks); }
      installPayloads(values); setLoadErrors((current) => without(current, ids));
    } catch {
      if (!disposed && manifest().revision === revision) setLoadErrors((current) => withValues(current, ids));
      else for (const [id, force] of entries) queuedLoads.set(id, force);
    } finally {
      ids.forEach((id) => loading.delete(id));
      if (queuedLoads.size && !loadQueued) { loadQueued = true; queueMicrotask(loadQueuedBlocks); }
    }
  }
  function installPayloads(values: BlockPayload[]) {
    touch(values.map((value) => value.id));
    setPayloads((current) => { const next = new Map(current); for (const value of values) { const local = dirty().get(value.id), alternatives = current.get(value.id)?.alternatives; next.set(value.id, { ...value, ...(local ? { bytes: local.bytes } : {}), ...(alternatives ? { alternatives } : {}) }); } return trim(next); });
  }
  async function ensure(ids: string[]) {
    const missing = ids.filter((id) => descriptor(id) && !payloads().has(id)); if (!missing.length) return true;
    const revision = manifest().revision;
    try { const values = await client.readBlocks(store, initial.id, revision, missing); if (manifest().revision !== revision) return ensure(ids); installPayloads(values); setLoadErrors((current) => without(current, missing)); return true; }
    catch { setLoadErrors((current) => withValues(current, missing)); return false; }
  }

  function bind(id: string, handle: BlockEditorHandle | null) { if (handle) editors.set(id, handle); else editors.delete(id); }
  function preview(id: string, bytes: Uint8Array | null) { editors.get(id)?.preview(bytes); }
  function focus(id: string, edge: "start" | "end" = "end") { queueMicrotask(() => editors.get(id)?.focus(edge)); }
  function mark(id: string, bytes: Uint8Array, origins = [id]) {
    const value = { bytes, origins, generation: ++generation };
    setDirty((current) => { const next = new Map(current); next.set(id, value); return next; });
    const payload = payloads().get(id); setPayload(id, { id, bytes, sources: payload?.sources ?? [], ...(payload?.alternatives ? { alternatives: payload.alternatives } : {}) }); scheduleSave();
  }
  function setFocus(id: string, value: boolean) { if (value) setFocused(id); else if (focused() === id) setFocused(null); }
  function scheduleSave() { if (conflicted()) return; if (saveTimer) clearTimeout(saveTimer); saveTimer = setTimeout(() => { saveTimer = null; void flush().catch((error) => options.onError?.("Save failed", error)); }, 800); }
  function setIdentifier(value: string) { const next = parseIdentifier(value).value; if (next === identifier()) return; identifierGeneration++; setIdentifierValue(next); scheduleSave(); }
  function reorder(order: string[]) {
    const map = new Map(blocks().map((block) => [block.id, block])); if (order.length !== map.size || order.some((id) => !map.has(id))) throw new Error("Invalid local block order");
    if (sameIds(order, blocks().map((block) => block.id))) return; orderGeneration++; setBlocks(order.map((id) => map.get(id)!)); scheduleSave();
  }

  function split(id: string, before: string, after: string) {
    if (locked()) return; const index = blocks().findIndex((block) => block.id === id), current = blocks()[index]; if (index < 0 || !current) return;
    const nextId = fresh("blk"), beforeBytes = markdownPacket(before), afterBytes = markdownPacket(after), nextDescriptor = { ...current, id: nextId, author: "draft", sourceCount: 1, byteLength: afterBytes.byteLength };
    orderGeneration++; setBlocks((values) => [...values.slice(0, index), { ...current, byteLength: beforeBytes.byteLength }, nextDescriptor, ...values.slice(index + 1)]);
    mark(id, beforeBytes, [id]); mark(nextId, afterBytes, [id]); focus(nextId, "start");
  }
  async function merge(id: string, direction: "previous" | "next") {
    if (locked()) return; const values = blocks(), index = values.findIndex((block) => block.id === id), otherIndex = direction === "previous" ? index - 1 : index + 1; if (index < 0 || otherIndex < 0 || otherIndex >= values.length) return;
    const survivor = direction === "previous" ? values[otherIndex] : values[index], removed = direction === "previous" ? values[index] : values[otherIndex];
    if (!await ensure([survivor.id, removed.id]) || locked()) return;
    const current = blocks(), currentIndex = current.findIndex((block) => block.id === id), currentOther = direction === "previous" ? currentIndex - 1 : currentIndex + 1; if (currentIndex < 0 || currentOther < 0 || currentOther >= current.length) return;
    const left = direction === "previous" ? sourceOf(survivor.id) : sourceOf(id), right = direction === "previous" ? sourceOf(id) : sourceOf(removed.id); if (left === null || right === null) return;
    const joined = `${left}${left && right ? "\n\n" : ""}${right}`, origins = direction === "previous" ? [survivor.id, id] : [id, removed.id];
    orderGeneration++; setBlocks(current.filter((block) => block.id !== removed.id)); mark(survivor.id, markdownPacket(joined), origins);
    setDirty((values) => { const next = new Map(values); next.delete(removed.id); return next; }); removePayload(removed.id); focus(survivor.id, "end");
  }
  function navigate(id: string, direction: "previous" | "next") { const values = blocks(), index = values.findIndex((block) => block.id === id), target = values[index + (direction === "previous" ? -1 : 1)]; if (!target) return; void ensure([target.id]).then((loaded) => { if (loaded) focus(target.id, direction === "previous" ? "end" : "start"); }); }
  function sourceOf(id: string) { const bytes = dirty().get(id)?.bytes ?? payloads().get(id)?.bytes; if (!bytes) return null; const decoded = decodeBlock(bytes); if (decoded.format !== "markdown") return null; const value = JSON.parse(new TextDecoder().decode(bytes)); return typeof value.text === "string" ? value.text : null; }

  function snapshot(): Snapshot { return { dirty: new Map(dirty()), order: blocks().map((block) => block.id), orderGeneration, identifier: identifier(), identifierGeneration }; }
  function patch(saved: Snapshot, extra: Array<{ id: string; bytes: Uint8Array }> = [], identifierOverride?: string) {
    const writes: BlockWrite[] = [...saved.dirty].map(([id, value]) => ({ id, origins: value.origins, bytes: value.bytes }));
    for (const value of extra) writes.push({ id: value.id, origins: [], bytes: value.bytes });
    const nextIdentifier = identifierOverride ?? saved.identifier;
    return { revision: manifest().revision, ...(nextIdentifier !== manifest().identifier ? { identifier: nextIdentifier } : {}), order: [...saved.order, ...extra.map((block) => block.id)], writes };
  }
  function enqueue<T>(work: () => Promise<T>): Promise<T> {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    const run = mutation.catch(() => {}).then(async () => {
      if (disposed) throw new Error("Thread session is closed");
      mutating = true; setSaving(true);
      try { return await work(); }
      finally { setSaving(false); mutating = false; queueMicrotask(drainEvents); }
    });
    mutation = run.then(() => {}, () => {}); return run;
  }
  async function saveCurrent() {
    if (conflicted()) throw new Error("Thread changed elsewhere. Reload before saving.");
    if (!changed()) return manifest();
    const saved = snapshot(), result = await client.save(store, initial.id, patch(saved));
    if (result.collapsedTo) { options.onCollapse?.(result.collapsedTo); return result.manifest; }
    accept(result.manifest, saved, [], false, result.acknowledged); return result.manifest;
  }
  function flush() { return enqueue(saveCurrent); }
  function accept(next: ThreadManifest, saved?: Snapshot, required: string[] = [], invalidate = false, acknowledged: BlockAcknowledgement[] = []) {
    const preserveOrder = Boolean(saved && orderGeneration !== saved.orderGeneration), preserveIdentifier = Boolean(saved && identifierGeneration !== saved.identifierGeneration), currentBlocks = blocks(), currentDirty = dirty();
    setManifest(next);
    if (!preserveIdentifier) setIdentifierValue(next.identifier);
    setDirty((values) => { if (!saved) return values; const result = new Map(values); for (const [id, value] of saved.dirty) if (result.get(id)?.generation === value.generation) result.delete(id); return result; });
    const server = new Map(next.blocks.map((block) => [block.id, block]));
    if (preserveOrder) {
      const local = currentBlocks.map((block) => server.get(block.id) ? mergeDescriptor(server.get(block.id)!, block, currentDirty.has(block.id)) : block), seen = new Set(local.map((block) => block.id));
      for (const id of required) if (!seen.has(id) && server.has(id)) local.push(server.get(id)!);
      setBlocks(local);
    } else setBlocks(next.blocks.map((block) => mergeDescriptor(block, currentBlocks.find((value) => value.id === block.id), currentDirty.has(block.id))));
    const live = new Set(blocks().map((block) => block.id));
    setPayloads((values) => {
      const result = invalidate ? new Map([...values].filter(([id]) => live.has(id) && currentDirty.has(id))) : new Map([...values].filter(([id]) => live.has(id)));
      for (const item of acknowledged) {
        const bytes = currentDirty.get(item.id)?.bytes ?? saved?.dirty.get(item.id)?.bytes ?? values.get(item.id)?.bytes;
        if (bytes && live.has(item.id)) result.set(item.id, { id: item.id, bytes, sources: item.sources });
      }
      return trim(result);
    });
    options.onManifest?.(next);
  }

  async function submit(markdown: string) {
    if (output().active || conflicted()) return;
    const packets = markdownBlocks(markdown).map((block) => block.raw.trimEnd()).filter(Boolean).map((text) => ({ id: fresh("blk"), bytes: markdownPacket(text) })); if (!packets.length) return;
    return enqueue(async () => {
      const saved = snapshot(); setOutput({ reasoning: "", response: "", active: true, error: "" });
      try {
        const result = await client.complete(store, initial.id, patch(saved, packets));
        accept(result.manifest, saved, packets.map((value) => value.id), false, result.acknowledged);
        for (const value of packets) setPayload(value.id, { id: value.id, bytes: value.bytes, sources: [] });
      } catch (error) { setOutput((value) => ({ ...value, active: false, error: error instanceof Error ? error.message : String(error) })); throw error; }
    });
  }
  function resolveSource(block: string, index: number) {
    const payload = payloads().get(block), source = payload?.sources[index]; if (!payload || !source) return Promise.reject(new Error("Unknown block source"));
    const cached = payload.alternatives?.get(index); if (cached) return Promise.resolve(cached);
    const key = `${block}/${index}`, pending = sourceLoads.get(key); if (pending) return pending;
    const request = client.readSource(store, source).then((bytes) => {
      const current = payloads().get(block); if (current) { const alternatives = new Map(current.alternatives); alternatives.set(index, bytes); setPayload(block, { ...current, alternatives }); }
      sourceLoads.delete(key); return bytes;
    }, (error) => { sourceLoads.delete(key); throw error; });
    sourceLoads.set(key, request); return request;
  }
  function applySource(block: string, source: number, bytes?: Uint8Array) { if (locked()) return Promise.resolve(); return enqueue(async () => { await saveCurrent(); const result = await client.applySource(store, initial.id, manifest().revision, block, source); if (result.collapsedTo) options.onCollapse?.(result.collapsedTo); else { accept(result.manifest, undefined, [], false, result.acknowledged); if (bytes) { const item = result.acknowledged.find((value) => value.id === block); setPayload(block, { id: block, bytes, sources: item?.sources ?? [] }); } } }); }
  function fork(block: string) { if (locked()) return Promise.reject(new Error("Thread cannot be forked while completion is active.")); return enqueue(async () => { await saveCurrent(); return client.fork(store, initial.id, manifest().revision, block); }); }
  function release() { return enqueue(async () => { await saveCurrent(); return client.release(store, initial.id); }); }
  function leave() { return enqueue(async () => { await saveCurrent(); const redirect = blocks().length ? await client.release(store, initial.id) : (await client.delete(store, initial.id), undefined); dispose(); return redirect; }); }

  async function refresh(revision?: string, appended: string[] = [], invalidate = true) {
    if (revision && revision === manifest().revision) { if (appended.length) request(appended, true); return; }
    if (changed()) { conflict(); return; }
    const next = await client.manifest(store, initial.id); if (changed()) { conflict(); return; }
    accept(next, undefined, [], invalidate); if (appended.length) { await ensure(appended); setOutput((value) => ({ ...value, reasoning: "", response: "" })); }
  }
  function conflict() { setConflicted(true); if (!conflictNotified) { conflictNotified = true; options.onConflict?.(); } }
  async function refreshCatalog() {
    const next = await client.manifest(store, initial.id).catch(() => null); if (!next) return;
    if (next.revision === manifest().revision) { setManifest((current) => ({ ...current, updated: next.updated, forkPoints: next.forkPoints })); options.onManifest?.(next); }
    else await refresh(next.revision);
  }
  function handleEvent(event: ZincEvent) {
    if (event.store !== store) return;
    if (event.type === "catalog") { if (mutating) pendingEvents.push(event); else void refreshCatalog(); return; }
    if (event.thread !== initial.id) return;
    if (event.type === "reasoning" || event.type === "response") setOutput((value) => ({ ...value, active: true, [event.type]: value[event.type] + event.text }));
    else if (event.type === "error") setOutput((value) => ({ ...value, active: false, error: event.text }));
    else if (event.type === "deleted") { if (!mutating && event.redirect) options.onCollapse?.(event.redirect); }
    else if (mutating) pendingEvents.push(event);
    else if (event.type === "done") { setOutput((value) => ({ ...value, active: false })); void refresh(event.revision, [], false); }
    else if (event.type === "append") void refresh(event.revision, event.blocks);
    else if (event.type === "update") void refresh(event.revision);
  }
  function drainEvents() { if (mutating || !pendingEvents.length || disposed) return; const events = pendingEvents.splice(0); for (const event of events) handleEvent(event); }
  function pinned() { return new Set([...dirty().keys(), ...(focused() ? [focused()!] : [])]); }

  return { store, id: initial.id, manifest, blocks, payloads, dirty, identifier, focused, saving, conflicted, output, loadErrors, status, locked, request, retain, bind, preview, focus, mark, setFocus, split, merge, navigate, reorder, setIdentifier, flush, submit, resolveSource, applySource, fork, release, leave, refresh, pinned, dispose };
}
export type ThreadSession = ReturnType<typeof createThreadSession>;
function fresh(prefix: string) { return `${prefix}_${crypto.randomUUID()}`; }
function sameOrder(left: BlockDescriptor[], right: BlockDescriptor[]) { return sameIds(left.map((block) => block.id), right.map((block) => block.id)); }
function sameIds(left: string[], right: string[]) { return left.length === right.length && left.every((id, index) => id === right[index]); }
function mergeDescriptor(server: BlockDescriptor, local: BlockDescriptor | undefined, preserve: boolean) { return preserve && local ? { ...server, byteLength: local.byteLength } : server; }
function without(values: Set<string>, removed: string[]) { const next = new Set(values); removed.forEach((value) => next.delete(value)); return next; }
function withValues(values: Set<string>, added: string[]) { const next = new Set(values); added.forEach((value) => next.add(value)); return next; }
