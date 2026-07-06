import { getStores, type StoreRef } from "~/lib/stores";
import { listThreads, loadThread } from "~/lib/db";
import type { ThreadBootstrap } from "~/thread/ThreadPage";

export async function readThreadBootstrap(storeParam?: string, threadParam?: string): Promise<ThreadBootstrap> {
  const registry = await getStores();
  const stores = uniqueStores([...(registry.recent || []), ...(registry.saved || [])]);
  const store = storeParam ? refForPath(storeParam) : stores[0] ?? null;
  if (!store) return { stores, store: null, threads: [], active: null };

  const threads = await listThreads(store.path);
  const threadId = threadParam || threads[0]?.id || null;
  const active = threadId ? await loadThread(threadId, store.path).catch(() => null) : null;
  return { stores: uniqueStores([store, ...stores]), store, threads, active };
}

export function stringParam(value: unknown) {
  return typeof value === "string" && value ? value : undefined;
}

function refForPath(path: string): StoreRef {
  return { path, name: path, meta: {} };
}

function uniqueStores(values: StoreRef[]) {
  const seen = new Set<string>();
  const stores: StoreRef[] = [];
  for (const store of values) {
    if (seen.has(store.path)) continue;
    seen.add(store.path);
    stores.push(store);
  }
  return stores;
}
