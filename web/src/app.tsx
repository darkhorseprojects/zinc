import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg?raw";
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
  if (props.initial.store && props.initial.manifest) setSession(openSession(props.initial.store, props.initial.manifest));

  onMount(() => {
    writeUrl(store(), session()?.id ?? null, true);
    const events = zincClient.subscribe((event) => { if (event.store === store() && ["update", "done", "deleted"].includes(event.type)) void refreshThreads(); });
    const removeDrop = installDropController({ active: setDropActive, drop: handleDrop });
    const pop = () => { const query = new URLSearchParams(location.search), path = query.get("store"), id = query.get("thread"); if (path !== store()) void chooseStore(path, false, id); else if (id !== session()?.id) void chooseThread(id, false); };
    window.addEventListener("popstate", pop); onCleanup(() => { events(); removeDrop(); window.removeEventListener("popstate", pop); session()?.dispose(); zincClient.close(); });
  });

  function openSession(path: string, manifest: ThreadManifest) { return createThreadSession(zincClient, path, manifest, { onCollapse: (id) => void chooseThread(id), onManifest: (next) => setThreads((values) => values.map((value) => value.id === next.id ? { ...value, identifier: next.identifier, revision: next.revision, updated: Math.floor(Date.now() / 1000) } : value)) }); }
  async function closeSession() { const current = session(); if (!current) return; try { const redirect = await current.release(); current.dispose(); setSession(null); if (redirect) await chooseThread(redirect); } catch (error) { showSystemToast({ title: "Thread save failed", detail: describeError(error) }); throw error; } }
  async function refreshThreads(path = store()) { if (path) setThreads(await zincClient.threads(path)); }
  async function chooseThread(id: string | null, updateUrl = true) { const path = store(); if (!path || id === session()?.id) return; try { const current = session(); if (current) { await current.flush(); current.dispose(); } if (!id) { setSession(null); if (updateUrl) writeUrl(path, null); return; } const manifest = await zincClient.manifest(path, id); setSession(openSession(path, manifest)); if (updateUrl) writeUrl(path, id); } catch (error) { showSystemToast({ title: "Thread switch failed", detail: describeError(error) }); } }
  async function createThread(path = store()) { if (!path) return null; const current = session(); if (current) { await current.flush(); current.dispose(); } const created = await zincClient.create(path); setSession(openSession(path, created.manifest)); await refreshThreads(path); writeUrl(path, created.id); return session(); }
  async function newThread() { if (!store() || session() && !session()!.blocks().length) return; try { await createThread(); } catch (error) { showSystemToast({ title: "New thread failed", detail: describeError(error) }); } }
  async function chooseStore(path: string | null, updateUrl = true, requested: string | null = null) { try { const current = session(); if (current) { await current.flush(); current.dispose(); } setSession(null); if (!path) { setStore(null); setThreads([]); if (updateUrl) writeUrl(null, null); return; } const values = await zincClient.addStore(path); setStores(values); setStore(path); const found = await zincClient.threads(path); setThreads(found); const target = requested && found.some((item) => item.id === requested) ? requested : found[0]?.id ?? null; if (target) { const manifest = await zincClient.manifest(path, target); setSession(openSession(path, manifest)); } if (updateUrl) writeUrl(path, target); } catch (error) { showSystemToast({ title: "Store switch failed", detail: describeError(error) }); } }
  async function send(markdown: string) { let current = session(); if (!current) current = await createThread(); if (!current) return; try { await current.submit(markdown); await refreshThreads(); } catch (error) { showSystemToast({ title: "Completion failed", detail: describeError(error) }); } }
  async function handleDrop(data: DataTransfer) { const path = droppedStorePath(data); if (path) return chooseStore(path); if (!store()) { showSystemToast("The browser did not expose a database file path."); return; } const value = await droppedText(data); if (value) setPromptAppend(value); }
  function writeUrl(path: string | null, thread: string | null, replace = false) { const query = new URLSearchParams(); if (path) query.set("store", path); if (thread) query.set("thread", thread); history[replace ? "replaceState" : "pushState"](null, "", `/${query.size ? `?${query}` : ""}`); }

  return <div class="app-shell" data-drop-active={dropActive() || undefined}>
    <FileDropOverlay active={dropActive()} />
    <TopBar stores={stores()} store={stores().find((value) => value.path === store()) ?? null} threads={threads()} thread={session()?.manifest() ?? null} identifier={session()?.identifier() ?? ""} dirty={Boolean(session()?.dirty().size)} saving={session()?.saving() ?? false} onIdentifier={(value) => session()?.setIdentifier(value)} onStore={(path) => void chooseStore(path)} onThread={(id) => void chooseThread(id)} onNew={() => void newThread()} canNew={Boolean(store()) && Boolean(session()?.blocks().length)} />
    <Show when={store()} fallback={<div class="empty-store-state"><div class="empty-db-icon"><Icon svg={databaseSvg} size={34} /></div><div class="empty-db-copy">Drop a database file to open Zinc.</div></div>}>
      <main class="thread-zone"><div class="thread-column"><Show when={session()} keyed>{(current) => <ThreadView client={zincClient} session={current} onThread={(id) => void chooseThread(id)} onFork={(id) => void chooseThread(id)} />}</Show></div></main>
      <Prompt onSend={send} disabled={session()?.output().active ?? false} appendText={promptAppend()} onAppendTextConsumed={() => setPromptAppend("")} />
    </Show>
    <Toasts />
  </div>;
}
