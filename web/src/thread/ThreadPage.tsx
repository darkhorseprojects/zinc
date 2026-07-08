import { createEffect, createSignal, onCleanup, onMount, Show } from "solid-js";
import { ZincEditor, type ZincEditorHandle } from "~/thread/ZincEditor";
import { FileDropOverlay } from "~/shell/FileDropOverlay";
import { Icon } from "~/shell/Icon";
import { PromptDock } from "~/thread/DraftDock";
import { TopBar } from "~/shell/TopBar";
import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg?raw";
import { describeError, showSystemToast } from "~/ui/toast";
import type { StoreRef } from "~/lib/stores";
import type { ThreadListItem, ThreadView, Packet } from "~/lib/types";

export type ThreadBootstrap = {
  stores: StoreRef[];
  store: StoreRef | null;
  threads: ThreadListItem[];
  active: ThreadView | null;
};

export default function Home(props: { initial?: ThreadBootstrap }) {
  const [stores, setStores] = createSignal<StoreRef[]>(props.initial?.stores ?? []);
  const [store, setStore] = createSignal<StoreRef | null>(props.initial?.store ?? null);
  const [threads, setThreads] = createSignal<ThreadListItem[]>(props.initial?.threads ?? []);
  const [active, setActive] = createSignal<ThreadView | null>(props.initial?.active ? normalizeThreadView(props.initial.active) : null);
  const [busy, setBusy] = createSignal(false);
  const [dropActive, setDropActive] = createSignal(false);
  const [promptAppendText, setPromptAppendText] = createSignal<string | null>(null);

  let removeDropController = () => {};
  let threadHandle: ZincEditorHandle | null = null;
  let appliedBootstrapKey = bootstrapKey(props.initial);

  createEffect(() => {
    const key = bootstrapKey(props.initial);
    if (!props.initial || key === appliedBootstrapKey) return;
    appliedBootstrapKey = key;
    setStores(props.initial.stores);
    setStore(props.initial.store);
    setThreads(props.initial.threads);
    setActive(props.initial.active ? normalizeThreadView(props.initial.active) : null);
  });

  onMount(() => {
    if (!props.initial) void loadBootstrap();
    if (typeof window !== "undefined") {
      window.addEventListener("popstate", handlePopState);
      removeDropController = installDropController({ active: setDropActive, drop: handleDrop });
    }
  });

  onCleanup(() => {
    if (saveTimeout) clearTimeout(saveTimeout);
    if (typeof window !== "undefined") window.removeEventListener("popstate", handlePopState);
    removeDropController();
  });

  createEffect(() => {
    const current = store();
    if (!current) {
      setThreads([]);
      setActive(null);
      return;
    }
    void loadThreads(current.path);
  });

  function sourceFromUrl() {
    if (typeof window === "undefined") return { store: null, thread: null };
    const params = new URLSearchParams(window.location.search);
    return { store: params.get("store"), thread: params.get("thread") };
  }

  function writeSourceUrl(storePath: string | null, threadId: string | null) {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams();
    if (storePath) params.set("store", storePath);
    if (threadId) params.set("thread", threadId);
    const query = params.toString();
    const next = `/${query ? `?${query}` : ""}${window.location.hash}`;
    const current = `${window.location.pathname}${window.location.search}${window.location.hash}`;
    if (next !== current) window.history.replaceState(null, "", next);
  }

  function refForPath(path: string): StoreRef {
    const name = path.split(/[/\\]/).pop() || path;
    return { path, name };
  }

  function hydrateFromUrl(knownStores = stores()) {
    const source = sourceFromUrl();
    if (!source.store) {
      if (!store() && knownStores[0]) setStore(knownStores[0]);
      return;
    }
    const next = knownStores.find((item) => item.path === source.store) ?? refForPath(source.store);
    if (store()?.path !== next.path) setStore(next);
  }

  function handlePopState() {
    hydrateFromUrl();
    const source = sourceFromUrl();
    if (source.thread && source.thread !== active()?.id) void loadThread(source.thread, false);
  }

  async function loadBootstrap() {
    const source = sourceFromUrl();
    const params = new URLSearchParams();
    if (source.store) params.set("store", source.store);
    if (source.thread) params.set("thread", source.thread);
    const res = await fetch(`/api/bootstrap${params.toString() ? `?${params}` : ""}`);
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json() as ThreadBootstrap;
    setStores(data.stores || []);
    setStore(data.store || null);
    setThreads(data.threads || []);
    setActive(data.active ? normalizeThreadView(data.active) : null);
  }

  async function loadStores() {
    await loadBootstrap();
  }

  async function loadThreads(storePath: string) {
    const res = await fetch(`/api/threads?store=${encodeURIComponent(storePath)}`);
    const data = await res.json();
    const nextThreads = data.threads || [];
    setThreads(nextThreads);

    const urlThread = sourceFromUrl().thread;

    if (urlThread && active()?.id !== urlThread) return await loadThread(urlThread, false);
    if (active() && nextThreads.some((t: ThreadListItem) => t.id === active()?.id)) return nextThreads;
    if (nextThreads[0]) await loadThread(nextThreads[0].id, true);
    else setActive(null);
    return nextThreads;
  }

  async function loadThread(id: string, updateUrl = true, storePath = store()?.path) {
    if (!storePath) return;
    threadHandle = null;
    const res = await fetch(`/api/thread?id=${encodeURIComponent(id)}&store=${encodeURIComponent(storePath)}`);
    if (!res.ok) throw new Error(await res.text());
    const view = normalizeThreadView(await res.json());
    setActive(view);
    if (updateUrl) writeSourceUrl(storePath, view.id);
    return view;
  }

  async function createThread(storePath = store()?.path) {
    if (!storePath) return null;
    threadHandle = null;
    const res = await fetch("/api/threads", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ store: storePath }),
    });
    if (!res.ok) throw new Error(await res.text());
    const view = normalizeThreadView(await res.json());
    setActive(view);
    writeSourceUrl(storePath, view.id);
    await loadThreads(storePath);
    return view;
  }

  async function continueThreadStream(input: { threadId: string; baseRevision?: string; mdx?: string; draft?: string }, storePath: string) {
    const res = await fetch("/api/thread/continue/stream", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...input, store: storePath }),
    });
    if (!res.ok) throw new Error(await res.text());
    if (!res.body) throw new Error("Continuation stream returned no body.");

    let latest = active();
    let packets = { ...(latest?.packets ?? {}) };
    let buffer = "";
    const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += value;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) if (line.trim()) applyFrame(JSON.parse(line));
    }
    if (buffer.trim()) applyFrame(JSON.parse(buffer));
    return latest;

    function applyFrame(frame: any) {
      if (frame.type === "error") {
        showSystemToast({ title: "Continuation failed", detail: frame.message });
        return;
      }
      if (frame.type === "output") return;
      if (frame.type === "packet") {
        const packet = normalizePacket(frame.packet);
        packets = { ...packets, [packet.id]: packet };
        latest = latest ? { ...latest, packets } : latest;
        if (latest) setActive(latest);
        return;
      }
      if (frame.type === "thread") {
        latest = normalizeThreadView(frame.thread);
        packets = { ...latest.packets };
        setActive(latest);
      }
    }
  }

  const [editorDirty, setEditorDirty] = createSignal(false);
  const [isSaving, setIsSaving] = createSignal(false);
  let saveTimeout: ReturnType<typeof setTimeout> | null = null;
  let saving: Promise<ThreadView | null> | null = null;

  function triggerAutosave() {
    if (!threadHandle || !active() || !store()) return;
    if (saveTimeout) clearTimeout(saveTimeout);
    saveTimeout = setTimeout(() => { void saveCurrentThread(); }, 800);
  }

  async function flushSave() {
    if (saveTimeout) {
      clearTimeout(saveTimeout);
      saveTimeout = null;
    }
    return await saveCurrentThread();
  }

  async function saveCurrentThread(): Promise<ThreadView | null> {
    if (saving) {
      await saving;
      return await saveCurrentThread();
    }

    saving = saveCurrentThreadOnce().finally(() => {
      saving = null;
    });
    return await saving;
  }

  async function saveCurrentThreadOnce() {
    const handle = threadHandle;
    const current = active();
    const currentStore = store();
    if (!handle || !current || !currentStore || !handle.isDirty()) return current;

    const mdx = await handle.snapshotMdx();
    const baseRevision = handle.baseRevision();

    setIsSaving(true);
    try {
      const res = await fetch("/api/thread", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          id: current.id,
          revision: baseRevision,
          mdx,
          store: currentStore.path,
        }),
      });
      if (res.ok) {
        const updatedView = normalizeThreadView(await res.json());
        setActive(updatedView);
        if (threadHandle === handle) {
          handle.acknowledgeSave(updatedView.revision, mdx);
          setEditorDirty(handle.isDirty());
        }
        return updatedView;
      }
      if (res.status === 409) {
        showSystemToast({ title: "Conflict detected", detail: "Local edits were kept. Reload or save again after reviewing." });
        throw new Error("Thread changed before this edit could be saved.");
      }
      throw new Error(await res.text());
    } catch (err) {
      console.error("Autosave failed:", err);
      throw err;
    } finally {
      setIsSaving(false);
    }
  }

  async function currentThreadMdx() {
    return threadHandle ? await threadHandle.snapshotMdx() : active()?.mdx ?? "";
  }

  async function discardActiveThreadIfEmpty() {
    const current = active();
    const currentStore = store();
    if (!current || !currentStore) return false;

    const mdx = await currentThreadMdx();
    if (threadHasContent(mdx)) return false;

    const res = await fetch(`/api/thread?id=${encodeURIComponent(current.id)}&store=${encodeURIComponent(currentStore.path)}`, {
      method: "DELETE",
    });
    if (!res.ok) throw new Error(await res.text());
    const result = await res.json();
    if (!result.deleted) return false;

    if (active()?.id === current.id) setActive(null);
    setThreads((items) => items.filter((item) => item.id !== current.id));
    setEditorDirty(false);
    threadHandle = null;
    return true;
  }

  async function handleThreadChange(id: string | null) {
    const currentStore = store();
    if (!currentStore || busy()) return;
    if (id && id === active()?.id) return;

    if (threadHasContent(await currentThreadMdx())) await flushSave();
    else await discardActiveThreadIfEmpty();

    if (id) await loadThread(id, true, currentStore.path);
    else await createThread(currentStore.path);
    await loadThreads(currentStore.path);
  }

  async function handleNewThread() {
    if (!store() || busy()) return;

    if (!active()) {
      await createThread();
      return;
    }

    const mdx = await currentThreadMdx();
    if (!threadHasContent(mdx)) return;

    await flushSave();
    await createThread();
  }

  async function sendPrompt(text: string) {
    const base = active() || (await createThread());
    const currentStore = store();
    if (!base || !currentStore || busy()) return;

    setBusy(true);
    try {
      const savedThread = await flushSave();
      const baseRevision = savedThread?.revision ?? (threadHandle ? threadHandle.baseRevision() : undefined);
      const next = await continueThreadStream({ threadId: base.id, baseRevision, draft: text }, currentStore.path);
      if (next) {
        writeSourceUrl(currentStore.path, next.id);
        await loadThreads(currentStore.path);
      }
    } catch (err) {
      showSystemToast({ title: "Continuation failed", detail: describeError(err) });
    } finally {
      setBusy(false);
    }
  }

  async function handleStoreChange(path: string | null) {
    if (threadHasContent(await currentThreadMdx())) await flushSave();
    else await discardActiveThreadIfEmpty();
    if (!path) {
      setStore(null);
      setActive(null);
      writeSourceUrl(null, null);
      return;
    }
    const next = refForPath(path);
    setStore(next);
    setActive(null);
    writeSourceUrl(next.path, null);
    await fetch("/api/stores", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ op: "add", storePath: next.path, storeName: next.name }),
    });
    await loadStores();
  }

  async function handleDrop(data: DataTransfer) {
    const storePath = droppedStorePath(data);
    if (storePath) {
      await handleStoreChange(storePath);
      return;
    }
    if (!store()) {
      showSystemToast("The browser did not expose a database file path.");
      return;
    }
    const text = await droppedText(data);
    if (text) setPromptAppendText(text);
  }

  return (
    <div class="app-shell" data-drop-active={dropActive() ? "true" : undefined}>
      <div class="app-bg" />
      <FileDropOverlay active={dropActive()} />
      <TopBar
        store={store()}
        stores={stores()}
        thread={active() ? { id: active()!.id, revision: active()!.revision, updated: active()!.updated, title: threadTitle(active()!) } : null}
        threads={threads().map((t) => ({ id: t.id, revision: t.revision, updated: t.updated, title: t.label }))}
        isSaving={isSaving()}
        isDirty={editorDirty()}
        onStoreChange={handleStoreChange}
        onThreadChange={(id) => { void handleThreadChange(id); }}
        canNewThread={Boolean(store()) && (!active() || editorDirty() || threadHasContent(active()!.mdx))}
        onNewThread={() => { void handleNewThread(); }}
      />
      <Show
        when={store()}
        fallback={
          <div class="empty-store-state">
            <div class="empty-db-icon"><Icon svg={databaseSvg} size={34} /></div>
            <div class="empty-db-copy">Drop a database file to open Zinc.</div>
          </div>
        }
      >
        <main class="thread-zone">
          <div class="thread-column">
            <Show when={active()} fallback={<div class="empty-thread-hint" />}>
              <ZincEditor
                mdx={active()?.mdx ?? ""}
                baseRevision={active()?.revision ?? ""}
                editable={!busy()}
                busy={busy()}
                bind={(handle) => { threadHandle = handle; }}
                onDirtyChange={(dirty) => {
                  setEditorDirty(dirty);
                  if (dirty) triggerAutosave();
                }}
              />
            </Show>
          </div>
        </main>
        <PromptDock onSend={sendPrompt} disabled={busy()} appendText={promptAppendText()} onAppendTextConsumed={() => setPromptAppendText(null)} />
      </Show>
    </div>
  );
}

function bootstrapKey(value: ThreadBootstrap | undefined) {
  if (!value) return "";
  return [value.store?.path ?? "", value.active?.id ?? "", value.active?.revision ?? "", value.threads.map((t) => t.id).join(",")].join("|");
}

function threadTitle(thread: ThreadView) {
  const text = thread.mdx.replace(/<[^>]+>/g, " ").trim();
  return text ? text.split(/\s+/).slice(0, 7).join(" ").slice(0, 60) : thread.id;
}

function threadHasContent(mdx: string) {
  return mdx.trim().length > 0;
}

function continuationToast(error: any) {
  if (error && typeof error === "object") {
    const stage = typeof error.stage === "string" ? error.stage : "continuation";
    const message = typeof error.message === "string" ? error.message : JSON.stringify(error);
    const detail = [
      stage,
      message,
      typeof error.detail === "string" ? error.detail : "",
      typeof error.stderr === "string" && error.stderr ? `stderr:\n${error.stderr}` : "",
    ].filter(Boolean).join("\n\n");
    return { title: `Continuation failed: ${stage}`, detail };
  }
  return { title: "Continuation failed", detail: String(error) };
}

function normalizeThreadView(raw: any): ThreadView {
  return { ...raw, packets: normalizePackets(raw.packets ?? {}) };
}

function normalizePackets(raw: Record<string, any>) {
  return Object.fromEntries(Object.entries(raw).map(([id, packet]) => [id, normalizePacket(packet)]));
}

function normalizePacket(raw: any): Packet {
  return { ...raw, bytes: decodeBytes(raw.bytes) };
}

function decodeBytes(value: any): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
  if (Array.isArray(value)) return new Uint8Array(value);
  if (value?.type === "Buffer" && Array.isArray(value.data)) return new Uint8Array(value.data);
  if (value && typeof value === "object") {
    const keys = Object.keys(value).filter((key) => /^\d+$/.test(key)).sort((a, b) => Number(a) - Number(b));
    return new Uint8Array(keys.map((key) => Number(value[key])));
  }
  return new Uint8Array();
}

function installDropController(options: { active: (active: boolean) => void; drop: (data: DataTransfer) => void | Promise<void> }) {
  let depth = 0;
  const enter = (event: DragEvent) => { if (!event.dataTransfer) return; claimDropEvent(event); depth++; options.active(true); };
  const over = (event: DragEvent) => { if (!event.dataTransfer) return; claimDropEvent(event); event.dataTransfer.dropEffect = "copy"; options.active(true); };
  const leave = (event: DragEvent) => { if (!event.dataTransfer) return; event.stopPropagation(); depth = Math.max(0, depth - 1); if (depth === 0 || !event.relatedTarget) options.active(false); };
  const drop = (event: DragEvent) => { if (!event.dataTransfer) return; claimDropEvent(event); depth = 0; options.active(false); void options.drop(event.dataTransfer); };
  for (const target of dropTargets()) {
    target.addEventListener("dragenter", enter as EventListener, true);
    target.addEventListener("dragover", over as EventListener, true);
    target.addEventListener("dragleave", leave as EventListener, true);
    target.addEventListener("drop", drop as EventListener, true);
  }
  return () => {
    for (const target of dropTargets()) {
      target.removeEventListener("dragenter", enter as EventListener, true);
      target.removeEventListener("dragover", over as EventListener, true);
      target.removeEventListener("dragleave", leave as EventListener, true);
      target.removeEventListener("drop", drop as EventListener, true);
    }
  };
}

function claimDropEvent(event: DragEvent) { event.preventDefault(); event.stopPropagation(); }
function dropTargets(): EventTarget[] { return [window, document, document.documentElement, document.body].filter(Boolean); }
function droppedStorePath(data: DataTransfer) {
  const uriPath = fileUrlPath(data.getData("text/uri-list"));
  if (uriPath && isDatabasePath(uriPath)) return uriPath;
  const textPath = absolutePath(data.getData("text/plain"));
  if (textPath && isDatabasePath(textPath)) return textPath;
  for (const file of Array.from(data.files)) {
    const exposedPath = absolutePath((file as any).path) || absolutePath((file as any).webkitRelativePath);
    if (exposedPath && isDatabasePath(exposedPath)) return exposedPath;
  }
  return null;
}
async function droppedText(data: DataTransfer | null) {
  if (!data) return "";
  const uriPath = fileUrlPath(data.getData("text/uri-list")) || fileUrlPath(data.getData("text/plain"));
  if (uriPath) return dirname(uriPath);
  const files = [...data.files];
  if (!files.length) return "";
  const labels = await Promise.all(files.map(async (file) => droppedFileLabel(file)));
  return labels.filter(Boolean).join("\n");
}
async function droppedFileLabel(file: File) {
  const exposedPath = absolutePath((file as any).path) || absolutePath((file as any).webkitRelativePath);
  if (exposedPath) return dirname(exposedPath);
  if (file.type.startsWith("text/") || /\.(md|markdown|kdl|txt|json|ts|tsx|js|jsx)$/i.test(file.name)) {
    const text = await file.text().catch(() => "");
    if (text.trim()) return [`${file.name}:`, "", text].join("\n");
  }
  return file.name;
}
function fileUrlPath(value: string) { const first = value.split(/\r?\n/).find((line) => line && !line.startsWith("#")); return first?.startsWith("file://") ? decodeURIComponent(new URL(first).pathname) : null; }
function dirname(path: string) { const index = path.lastIndexOf("/"); return index > 0 ? path.slice(0, index) : path; }
function absolutePath(value: unknown) { return typeof value === "string" && value.startsWith("/") ? value : null; }
function isDatabasePath(path: string) { return /\.(db|sqlite|sqlite3)$/i.test(path); }