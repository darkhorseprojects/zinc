import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg";
import { createSignal, onCleanup, onMount, Show } from "solid-js";
import { zincClient } from "./client";
import { Prompt } from "./completion/Prompt";
import { FileDropOverlay } from "./shell/FileDropOverlay";
import { Icon } from "./shell/Icon";
import { Toasts } from "./shell/Toasts";
import { TopBar } from "./shell/TopBar";
import { droppedStorePath, droppedText, installDropController } from "./thread/dropController";
import { createThreadSession, type ThreadSession } from "./thread/session";
import { ThreadView } from "./thread/ThreadView";
import type { Bootstrap, StoreRef, ThreadManifest, ThreadSummary } from "./thread/types";
import { describeError, showSystemToast } from "./ui/toast";

export default function App(props: { initial: Bootstrap }) {
  const [stores, setStores] = createSignal<StoreRef[]>(props.initial.stores), [store, setStore] = createSignal<string | null>(props.initial.store), [threads, setThreads] = createSignal<ThreadSummary[]>(props.initial.threads), [session, setSession] = createSignal<ThreadSession | null>(null), [promptAppend, setPromptAppend] = createSignal(""), [dropActive, setDropActive] = createSignal(false);
  let navigation = Promise.resolve();
  if (props.initial.store && props.initial.manifest) setSession(openSession(props.initial.store, props.initial.manifest));

  onMount(() => {
    writeUrl(store(), session()?.id ?? null, true);
    const events = zincClient.subscribe((event) => { if (event.store === store() && event.type === "catalog") void refreshThreads(); });
    const removeDrop = installDropController({ active: setDropActive, drop: handleDrop });
    const pop = () => { const query = new URLSearchParams(location.search), path = query.get("store"), id = query.get("thread"); if (path !== store()) void chooseStore(path, false, id); else if (id !== session()?.id) void chooseThread(id, false); };
    window.addEventListener("popstate", pop);
    onCleanup(() => { events(); removeDrop(); window.removeEventListener("popstate", pop); const current = session(); if (current) void current.leave().finally(() => zincClient.close()); else zincClient.close(); });
  });

  function openSession(path: string, next: ThreadManifest) { return createThreadSession(zincClient, path, next, { onCollapse: (id) => void chooseThread(id), onManifest: updateSummary, onError: (title, error) => showSystemToast({ title, detail: describeError(error) }), onConflict: () => showSystemToast({ title: "Save failed", detail: "The thread changed elsewhere. Local edits remain in this tab." }) }); }
  function updateSummary(next: ThreadManifest) { const summary = { id: next.id, identifier: next.identifier, title: next.title, revision: next.revision, updated: next.updated }; setThreads((values) => values.some((value) => value.id === next.id) ? values.map((value) => value.id === next.id ? summary : value) : [summary, ...values]); }
  function serial<T>(work: () => Promise<T>) { const run = navigation.catch(() => {}).then(work); navigation = run.then(() => {}, () => {}); return run; }
  async function refreshThreads(path = store()) { if (path) setThreads(await zincClient.threads(path)); }
  function chooseThread(id: string | null, updateUrl = true) { return serial(async () => {
    const path = store(); if (!path || id === session()?.id) return;
    try {
      const current = session(); if (current) await current.flush();
      const next = id ? await zincClient.manifest(path, id) : null;
      if (current) await current.leave(); setSession(next ? openSession(path, next) : null);
      if (updateUrl) writeUrl(path, id);
    } catch (error) { showSystemToast({ title: "Thread switch failed", detail: describeError(error) }); }
  }); }
  function createThread(path = store()) { return serial(async () => {
    if (!path) return null; const current = session(); if (current) await current.flush();
    const created = await zincClient.create(path);
    try { if (current) await current.leave(); }
    catch (error) { await zincClient.delete(path, created.id).catch(() => false); throw error; }
    const opened = openSession(path, created.manifest); setSession(opened); updateSummary(created.manifest); writeUrl(path, created.id); return opened;
  }); }
  async function newThread() { if (!store() || session() && !session()!.blocks().length) return; try { await createThread(); } catch (error) { showSystemToast({ title: "New thread failed", detail: describeError(error) }); } }
  function chooseStore(path: string | null, updateUrl = true, requested: string | null = null) { return serial(async () => {
    try {
      const current = session(); if (current) await current.flush();
      if (!path) { if (current) await current.leave(); setSession(null); setStore(null); setThreads([]); if (updateUrl) writeUrl(null, null); return; }
      const values = await zincClient.addStore(path), found = await zincClient.threads(path), target = requested && found.some((item) => item.id === requested) ? requested : found[0]?.id ?? null, next = target ? await zincClient.manifest(path, target) : null;
      if (current) await current.leave(); setStores(values); setStore(path); setThreads(found); setSession(next ? openSession(path, next) : null);
      if (updateUrl) writeUrl(path, target);
    } catch (error) { showSystemToast({ title: "Store switch failed", detail: describeError(error) }); }
  }); }
  async function send(markdown: string) { let current = session(); if (!current) current = await createThread(); if (!current) return; try { await current.submit(markdown); } catch (error) { showSystemToast({ title: "Completion failed", detail: describeError(error) }); throw error; } }
  async function handleDrop(data: DataTransfer) { const path = droppedStorePath(data); if (path) return chooseStore(path); if (!store()) { showSystemToast("The browser did not expose a database file path."); return; } const value = await droppedText(data); if (value) setPromptAppend(value); }
  function writeUrl(path: string | null, thread: string | null, replace = false) { const query = new URLSearchParams(); if (path) query.set("store", path); if (thread) query.set("thread", thread); history[replace ? "replaceState" : "pushState"](null, "", `/${query.size ? `?${query}` : ""}`); }

  return <div class="app-shell" data-drop-active={dropActive() || undefined}>
    <FileDropOverlay active={dropActive()} />
    <TopBar stores={stores()} store={stores().find((value) => value.path === store()) ?? null} threads={threads()} thread={session()?.manifest() ?? null} identifier={session()?.identifier() ?? ""} status={session()?.status() ?? "clean"} onIdentifier={(value) => session()?.setIdentifier(value)} onStore={(path) => void chooseStore(path)} onThread={(id) => void chooseThread(id)} onNew={() => void newThread()} canNew={Boolean(store()) && (!session() || Boolean(session()!.blocks().length))} />
    <Show when={store()} fallback={<div class="empty-store-state"><div class="empty-db-icon"><Icon svg={databaseSvg} size={34} /></div><div class="empty-db-copy">Drop a database file to open Zinc.</div></div>}>
      <main class="thread-zone"><div class="thread-column"><Show when={session()} keyed>{(current) => <ThreadView client={zincClient} session={current} onThread={(id) => void chooseThread(id)} onFork={(id) => void chooseThread(id)} />}</Show></div></main>
      <Prompt onSend={send} disabled={session()?.locked() ?? false} appendText={promptAppend()} onAppendTextConsumed={() => setPromptAppend("")} />
    </Show>
    <Toasts />
  </div>;
}
