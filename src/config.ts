import { readFile } from "node:fs/promises";
import { isIP } from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parse } from "kdljs";

export type Config = {
  store: string;
  turn: string;
  theme: string;
  url: string;
  port: number;
  author: string;
  completionsUrl: string;
  parallel: number;
  rawContextBytes: number;
  contextTokens: number;
  compactAt: number;
  packetOverflowBytes: number;
  shell: string;
  allowlist: string[];
};

type Node = { name: string; values?: unknown[]; children?: Node[] };

export function defaultConfigPath(env: NodeJS.ProcessEnv = process.env) {
  return env.ZINC_CONFIG || join(homedir(), ".zinc", "config.kdl");
}

export async function loadConfig(path = defaultConfigPath()) {
  return parseConfig(await readFile(path, "utf8"), dirname(path));
}

export function parseConfig(source: string, base: string): Config {
  const parsed = parse(source);
  if (parsed.errors?.length) throw new Error(`Zinc config KDL parse error: ${parsed.errors.map((error) => error.message).join(", ")}`);
  const nodes = (parsed.output ?? []) as Node[];
  const values = Object.fromEntries(nodes.map((node) => [node.name, node.values?.length === 1 ? node.values[0] : node.values]));
  const text = (name: string, fallback?: string) => {
    const value = values[name] ?? fallback;
    if (typeof value !== "string" || !value.trim()) throw new Error(`Zinc config field is required: ${name}`);
    return value.trim();
  };
  const integer = (name: string, fallback: number) => {
    const value = values[name] ?? fallback, number = typeof value === "number" ? value : Number(value);
    if (!Number.isInteger(number) || number <= 0) throw new Error(`Zinc config field must be a positive integer: ${name}`);
    return number;
  };
  const percentage = (name: string, fallback: number) => {
    const value = integer(name, fallback);
    if (value > 100) throw new Error(`Zinc config field must be a percentage from 1 to 100: ${name}`);
    return value;
  };
  const url = text("url", "localhost");
  if (!isIP(url) && (!/^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)$/.test(url) || /[/?#]/.test(url))) throw new Error("Zinc url must be a hostname or IP address");
  const port = integer("port", 5173);
  if (port > 65535) throw new Error("Zinc port must be between 1 and 65535");
  const completionsUrl = text("completions-url", "http://127.0.0.1:30000/v1/chat/completions");
  const endpoint = new URL(completionsUrl);
  if (!/^https?:$/.test(endpoint.protocol)) throw new Error("Zinc completions-url must use HTTP or HTTPS");
  const allowlist = nodes.find((node) => node.name === "allowlist")?.children?.flatMap(leaves) ?? [];
  return {
    store: path(text("store"), base),
    turn: path(text("turn"), base),
    theme: path(text("theme"), base),
    url,
    port,
    author: humanAuthor(text("author", "anonymous")),
    completionsUrl,
    parallel: integer("parallel", 4),
    rawContextBytes: integer("raw-context-bytes", 8192),
    contextTokens: integer("context-tokens", 32768),
    compactAt: percentage("compact-at", 80),
    packetOverflowBytes: integer("packet-overflow-bytes", 65536),
    shell: text("shell", process.platform === "win32" ? "pwsh" : "sh"),
    allowlist,
  };
}

export function humanAuthor(value: string) {
  const author = value.trim();
  if (!author || author.length > 64 || author === "agent" || author === "system") throw new Error("Zinc author must be 1-64 characters and not reserved");
  return author;
}

function path(value: string, base: string) { return resolve(base, value.replace(/^~(?=$|[\\/])/, homedir())); }
function leaves(node: Node): string[] { return node.children?.length ? node.children.flatMap(leaves) : [node.name]; }
