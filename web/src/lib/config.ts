import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parse as parseKdl } from "@bgotink/kdl";

export type ZincConfig = {
  store: string;
  turn: string;
  zincDir: string;
  agentDir: string;
  python: string;
  rawContextBytes: number;
  packetOverflowBytes: number;
  completionsUrl: string;
  shell: string;
  allowlist: string[];
};

type KdlNode = {
  getName(): string;
  getArguments(): unknown[];
  children?: { nodes: KdlNode[] };
};

const CONFIG_PATH = process.env.ZINC_CONFIG || join(defaultZincHome(), "config.kdl");

export async function loadConfig(): Promise<ZincConfig> {
  const raw = await readFile(CONFIG_PATH, "utf8");
  const parsed = parseConfigKdl(raw);
  const base = dirname(CONFIG_PATH);
  const zincDir = expandPath(requiredString(parsed["zinc-dir"] ?? parsed.zincDir, "zinc-dir"), base);
  const agentDir = expandPath(stringValue(parsed["agent-dir"] ?? parsed.agentDir) || join(zincDir, "agent"), base);
  const completionsUrl = stringValue(parsed["completions-url"] ?? parsed.completionsUrl) || "http://127.0.0.1:30000/v1/chat/completions";
  const shell = stringValue(parsed.shell) || "bun";
  const allowlistRaw = parsed.allowlist;
  const allowlist = Array.isArray(allowlistRaw)
    ? allowlistRaw
    : (typeof allowlistRaw === "string" && allowlistRaw.trim() ? [allowlistRaw] : []);

  return {
    store: expandPath(requiredString(parsed.store, "store"), base),
    turn: expandPath(requiredString(parsed.turn, "turn"), base),
    zincDir,
    agentDir,
    python: expandPath(stringValue(parsed.python) || join(agentDir, process.platform === "win32" ? ".venv/Scripts/python.exe" : ".venv/bin/python"), base),
    rawContextBytes: positiveInteger(parsed["raw-context-bytes"] ?? parsed.rawContextBytes, 8192),
    packetOverflowBytes: positiveInteger(parsed["packet-overflow-bytes"] ?? parsed.packetOverflowBytes, 65536),
    completionsUrl,
    shell,
    allowlist,
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

export function defaultZincHome() {
  if (process.env.ZINC_HOME) return process.env.ZINC_HOME;
  if (process.platform === "win32") return join(requiredEnv("APPDATA"), "Zinc");
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "Zinc");
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "zinc");
}

function parseConfigKdl(text: string): Record<string, unknown> {
  const doc = parseKdl(text) as { nodes: KdlNode[] };
  const result: Record<string, unknown> = {};
  for (const node of doc.nodes) {
    if (node.getName() === "allowlist") {
      result["allowlist"] = collectLeafNames(node);
    } else {
      result[node.getName()] = nodeToValue(node);
    }
  }
  return result;
}

function collectLeafNames(node: KdlNode): string[] {
  if (node.children?.nodes?.length) {
    return node.children.nodes.flatMap(collectLeafNames);
  }
  const name = node.getName();
  // Filter out any KDL boolean values or empty strings that could arise
  return name && name !== "true" && name !== "false" ? [name] : [];
}

function nodeToValue(node: KdlNode): unknown {
  if (node.children?.nodes?.length) {
    return Object.fromEntries(node.children.nodes.map(child => [child.getName(), child.getArguments().map(String)]));
  }
  const args = node.getArguments();
  if (args.length === 0) return true;
  if (args.length === 1) return String(args[0]);
  return args.map(String);
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

