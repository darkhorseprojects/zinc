import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parse as parseKdl } from "kdljs";

export type ZincConfig = {
  store: string;
  turn: string;
  zincDir: string;
  agentDir: string;
  rawContextBytes: number;
  packetOverflowBytes: number;
  completionsUrl: string;
  shell: string;
  allowlist: string[];
};

const CONFIG_PATH = process.env.ZINC_CONFIG || join(defaultZincHome(), "config.kdl");

export async function loadConfig(): Promise<ZincConfig> {
  const raw = await readFile(CONFIG_PATH, "utf8");
  const nodes = parseConfigNodes(raw);
  const values = Object.fromEntries(nodes.map((node) => [node.name, nodeToValue(node)]));
  const base = dirname(CONFIG_PATH);
  const zincDir = expandPath(requiredString(values["zinc-dir"], "zinc-dir"), base);
  const agentDir = expandPath(stringValue(values["agent-dir"]) || join(zincDir, "agent"), base);
  const allowlistNode = nodes.find((node) => node.name === "allowlist");

  return {
    store: expandPath(requiredString(values.store, "store"), base),
    turn: expandPath(requiredString(values.turn, "turn"), base),
    zincDir,
    agentDir,
    rawContextBytes: positiveInteger(values["raw-context-bytes"], 8192),
    packetOverflowBytes: positiveInteger(values["packet-overflow-bytes"], 65536),
    completionsUrl: stringValue(values["completions-url"]) || "http://127.0.0.1:30000/v1/chat/completions",
    shell: stringValue(values.shell) || defaultShell(),
    allowlist: allowlistNode ? leafNames(allowlistNode) : [],
  };
}

export async function activeStore(explicit?: string | null) {
  if (explicit) return explicit;
  if (process.env.ZINC_STORE) return process.env.ZINC_STORE;
  return (await loadConfig()).store;
}

export async function getZincConfig() {
  return await loadConfig();
}

export function defaultShell() {
  return process.platform === "win32" ? "pwsh" : "sh";
}

export function defaultZincHome() {
  if (process.env.ZINC_HOME) return process.env.ZINC_HOME;
  if (process.platform === "win32") return join(requiredEnv("APPDATA"), "Zinc");
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "Zinc");
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "zinc");
}

function parseConfigNodes(text: string): any[] {
  const parsed = parseKdl(text);
  if (parsed.errors?.length) throw new Error(`Zinc config KDL parse error: ${parsed.errors.map((e) => e.message).join(", ")}`);
  return parsed.output ?? [];
}

/** A leaf node's value; a node with children becomes a key -> value object. */
function nodeToValue(node: any): unknown {
  const children = node.children ?? [];
  if (children.length) return Object.fromEntries(children.map((child: any) => [child.name, nodeToValue(child)]));
  const args = node.values ?? [];
  if (args.length === 0) return true;
  if (args.length === 1) return String(args[0]);
  return args.map(String);
}

/** Every leaf node name under `node`, recursively (e.g. `allowlist { git; danger { rm; mv } }` -> ["git","rm","mv"]). */
function leafNames(node: any): string[] {
  const children = node.children ?? [];
  if (!children.length) return [];
  return children.flatMap((child: any) => (child.children?.length ? leafNames(child) : [child.name]));
}

function requiredString(value: unknown, name: string) {
  const text = stringValue(value);
  if (!text) throw new Error(`Zinc config field is required: ${name}`);
  return text;
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim() ? value : "";
}

function positiveInteger(value: unknown, fallback: number) {
  const number = typeof value === "number" ? value : Number(stringValue(value));
  if (!Number.isInteger(number) || number <= 0) return fallback;
  return number;
}

function requiredEnv(name: string) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function expandPath(path: string, base: string) {
  const expanded = path.replace(/^~(?=$|\/)/, homedir());
  return resolve(base, expanded);
}
