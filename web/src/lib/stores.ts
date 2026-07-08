import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { loadConfig } from "./config";

export interface StoreRef {
  path: string;
  name: string;
  meta: Record<string, any>;
}

export interface StoresData {
  saved: StoreRef[];
  recent: StoreRef[];
  aliases: Record<string, string>;
}

function normalizeStorePath(path: string) {
  return resolve(path.replace(/^~(?=$|\/)/, homedir()));
}

function ref(path: string, name?: string, meta: Record<string, any> = {}): StoreRef {
  const normalized = normalizeStorePath(path);
  return { path: normalized, name: name || normalized.split(/[/\\]/).pop() || normalized, meta };
}

async function registryPath() {
  const config = await loadConfig();
  return join(config.zincDir, "registry.jsonl");
}

async function readRegistry(): Promise<StoreRef[]> {
  let raw = "";
  try {
    raw = await readFile(await registryPath(), "utf8");
  } catch {
    return [];
  }

  const seen = new Set<string>();
  const stores: StoreRef[] = [];
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const item = JSON.parse(line);
    if (!item || typeof item !== "object" || typeof item.path !== "string") continue;
    const store = ref(item.path, typeof item.name === "string" ? item.name : undefined, isRecord(item.meta) ? item.meta : {});
    if (seen.has(store.path)) continue;
    seen.add(store.path);
    stores.push(store);
  }
  return stores;
}

async function writeRegistry(stores: StoreRef[]) {
  const path = await registryPath();
  await mkdir(dirname(path), { recursive: true });

  const seen = new Set<string>();
  const lines: string[] = [];
  for (const store of stores) {
    if (seen.has(store.path)) continue;
    seen.add(store.path);
    lines.push(JSON.stringify({ path: store.path, name: store.name, meta: store.meta || {} }));
  }

  await writeFile(path, lines.length ? `${lines.join("\n")}\n` : "", "utf8");
}

async function readStores(): Promise<StoresData> {
  const config = await loadConfig();
  const stores = await readRegistry();
  const defaultStore = ref(config.store);
  if (!stores.some((s) => s.path === defaultStore.path)) {
    stores.unshift(defaultStore);
  }
  return { saved: stores, recent: stores, aliases: {} };
}

export async function getStores(): Promise<StoresData> {
  return readStores();
}

export async function addRecent(store: { path: string; name?: string; meta?: Record<string, any> }): Promise<StoresData> {
  const next = ref(store.path, store.name, store.meta || {});
  const registry = await readRegistry();
  await writeRegistry([next, ...registry.filter((s) => s.path !== next.path)]);
  return readStores();
}

export async function saveStore(store: { path: string; name?: string; meta?: Record<string, any> }): Promise<StoresData> {
  return addRecent(store);
}

export async function unsaveStore(path: string): Promise<StoresData> {
  const target = normalizeStorePath(path);
  const registry = await readRegistry();
  await writeRegistry(registry.filter((s) => s.path !== target));
  return readStores();
}

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
