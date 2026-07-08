import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { loadConfig } from "./config";

export interface StoreRef {
  path: string;
  name: string;
}

function normalizeStorePath(path: string) {
  return resolve(path.replace(/^~(?=$|\/)/, homedir()));
}

function ref(path: string, name?: string): StoreRef {
  const normalized = normalizeStorePath(path);
  return { path: normalized, name: name || normalized.split(/[/\\]/).pop() || normalized };
}

async function jsonlPath() {
  const config = await loadConfig();
  return join(config.zincDir, "stores.jsonl");
}

async function readStoresFile(): Promise<StoreRef[]> {
  let raw = "";
  try {
    raw = await readFile(await jsonlPath(), "utf8");
  } catch {
    return [];
  }

  const seen = new Set<string>();
  const stores: StoreRef[] = [];
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const item = JSON.parse(line);
    if (!item || typeof item !== "object" || typeof item.path !== "string") continue;
    const store = ref(item.path, typeof item.name === "string" ? item.name : undefined);
    if (seen.has(store.path)) continue;
    seen.add(store.path);
    stores.push(store);
  }
  return stores;
}

async function writeStoresFile(stores: StoreRef[]) {
  const path = await jsonlPath();
  await mkdir(dirname(path), { recursive: true });
  const lines = stores.map((store) => JSON.stringify({ path: store.path, name: store.name }));
  await writeFile(path, lines.length ? `${lines.join("\n")}\n` : "", "utf8");
}

export async function listStores(): Promise<StoreRef[]> {
  const config = await loadConfig();
  const stores = await readStoresFile();
  const defaultStore = ref(config.store);
  if (!stores.some((s) => s.path === defaultStore.path)) stores.unshift(defaultStore);
  return stores;
}

export async function addStore(store: { path: string; name?: string }): Promise<StoreRef[]> {
  const next = ref(store.path, store.name);
  const existing = await readStoresFile();
  await writeStoresFile([next, ...existing.filter((s) => s.path !== next.path)]);
  return listStores();
}

export async function removeStore(path: string): Promise<StoreRef[]> {
  const target = normalizeStorePath(path);
  const existing = await readStoresFile();
  await writeStoresFile(existing.filter((s) => s.path !== target));
  return listStores();
}
