#!/usr/bin/env edge
import { spawn } from "node:child_process";
import { closeSync, cpSync, existsSync, mkdirSync, openSync, readFileSync, rmSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultConfigPath, loadConfig } from "../dist/config.js";
import { readPacket } from "../dist/packet.js";
import { Registry, Store } from "../dist/store.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
class CliError extends Error { constructor(message, usage) { super(message); this.usage = usage; } }

async function main(args = process.argv.slice(2)) {
  args = [...args]; const command = args.shift() ?? "help";
  if (command === "help") { none(args, "usage: zn help"); return help(); }
  if (command === "clean") return clean(args);
  const selected = option(args, "--config");
  if (command === "init" || command === "here") return initialize(command, args, selected);
  if (!["up", "down", "status", "logs", "stores", "packet", "thread"].includes(command)) throw new CliError(`unknown command: ${command}`);
  const path = resolve(selected ?? defaultConfigPath()), config = await loadConfig(path), state = dirname(path);
  if (command === "up") return up(config, state, path, args);
  if (command === "down") return down(state, args);
  if (command === "status") return status(config, state, path, args);
  if (command === "logs") return logs(state, args);
  if (command === "stores") return stores(config, state, args);
  if (command === "packet") return packet(config, state, args);
  return threads(config, state, args);
}

async function initialize(command, args, selected) {
  none(args, `usage: zn ${command}${command === "init" ? " [--config PATH]" : ""}`);
  if (command === "here" && selected) throw new CliError("--config is not valid with zn here");
  const path = resolve(command === "here" ? join(".zinc", "config.kdl") : selected ?? defaultConfigPath()), state = dirname(path), turn = join(state, "turn.md"), theme = join(state, "theme.kdl"), store = join(state, "zinc.db");
  mkdirSync(state, { recursive: true });
  if (!existsSync(turn)) writeFileSync(turn, readFileSync(join(root, "agent", "turn.md")));
  if (!existsSync(theme)) writeFileSync(theme, readFileSync(join(root, "defaults", "theme.kdl")));
  const definitions = join(state, "definitions"); if (!existsSync(definitions)) cpSync(join(root, "agent", "definitions"), definitions, { recursive: true });
  if (!existsSync(path)) writeFileSync(path, configText());
  const opened = await Store.open({ path: store, packets: join(state, "packets"), overflowBytes: 65536 }); await opened.close();
  line("initialized", store); line("config", path);
}

async function clean(args) {
  let here = flag(args, "--here");
  const user = flag(args, "--user"), thread = option(args, "--thread"), packet = option(args, "--packet");
  const usage = "usage: zn clean [--here | --user | --thread ID | --packet ID]";
  none(args, usage);
  if (!here && !user && !thread && !packet) here = true;
  if (Number(here) + Number(user) + Number(Boolean(thread)) + Number(Boolean(packet)) !== 1) throw new CliError("zn clean requires exactly one target", usage);
  const path = resolve(here ? join(".zinc", "config.kdl") : defaultConfigPath()), state = dirname(path);
  await down(state, []);
  if (here || user) return cleanConfig(path, state);
  const config = await loadConfig(path), store = await Store.open({ path: config.store, packets: join(state, "packets"), overflowBytes: config.packetOverflowBytes });
  try {
    if (thread) { const packets = await store.cleanThread(thread); rows([["deleted thread", thread], ["collected packets", String(packets)]]); }
    else { await store.cleanPacket(packet); line("deleted packet", packet); }
  } finally { await store.close(); }
}

async function cleanConfig(path, state) {
  if (!existsSync(path) && !existsSync(state)) return line("not found", state);
  const config = existsSync(path) ? await loadConfig(path) : null;
  const targets = [path, join(state, "stores.jsonl"), join(state, "definitions"), join(state, "web.log"), join(state, "web.pid")];
  const turn = config?.turn ?? join(state, "turn.md"), theme = config?.theme ?? join(state, "theme.kdl");
  if (inside(state, turn)) targets.push(turn);
  if (inside(state, theme)) targets.push(theme);
  const store = config?.store ?? join(state, "zinc.db");
  if (inside(state, store)) targets.push(store, `${store}-wal`, `${store}-shm`, join(state, "packets"));
  for (const target of targets) rmSync(target, { recursive: true, force: true });
  try { rmdirSync(state); } catch (error) { if (error?.code !== "ENOTEMPTY" && error?.code !== "ENOENT") throw error; }
  line("deleted config", state);
}
async function up(config, state, path, args) {
  none(args, "usage: zn up [--config PATH]"); const pidFile = join(state, "web.pid"), logFile = join(state, "web.log"), existing = pid(pidFile);
  if (existing && running(existing)) return line("already running", String(existing));
  if (existsSync(pidFile)) unlinkSync(pidFile); mkdirSync(state, { recursive: true });
  const log = openSync(logFile, "a"); let child;
  try { child = spawn("edge", [join(root, "dist", "server.js")], { cwd: root, env: { ...process.env, ZINC_CONFIG: path }, detached: true, stdio: ["ignore", log, log] }); }
  finally { closeSync(log); }
  child.unref(); writeFileSync(pidFile, String(child.pid));
  rows([["status", "running"], ["pid", String(child.pid)], ["url", `${config.url.includes(":") ? `[${config.url}]` : config.url}:${config.port}`], ["config", path], ["store", config.store], ["log", logFile]]);
}
async function down(state, args) {
  none(args, "usage: zn down [--config PATH]"); const file = join(state, "web.pid"), value = pid(file);
  if (!value || !running(value)) { if (existsSync(file)) unlinkSync(file); return line("stopped"); }
  process.kill(value, "SIGTERM"); for (let count = 0; count < 30 && running(value); count++) await new Promise((resolve) => setTimeout(resolve, 100));
  if (running(value)) process.kill(value, "SIGKILL"); if (existsSync(file)) unlinkSync(file); line("stopped", String(value));
}
function status(config, state, path, args) { none(args, "usage: zn status [--config PATH]"); const value = pid(join(state, "web.pid")); rows([["status", value && running(value) ? "running" : "stopped"], ...(value && running(value) ? [["pid", String(value)]] : []), ["config", path], ["store", config.store]]); }
function logs(state, args) { const requested = option(args, "--lines"), count = requested ? positive(requested, "--lines") : 200; none(args, "usage: zn logs [--lines N]"); const file = join(state, "web.log"); if (!existsSync(file)) return line("no log file", file); const source = readFileSync(file, "utf8"), trailing = source.endsWith("\n"); const value = (trailing ? source.slice(0, -1) : source).split("\n").slice(-count).join("\n"); process.stdout.write(value + (trailing && value ? "\n" : "")); }
async function stores(config, state, args) { none(args, "usage: zn stores"); const registry = await Registry.open(join(state, "stores.jsonl"), config.store); print(["PATH", "NAME"], registry.list().map((value) => [value.path, value.name])); }
async function packet(config, state, args) { const usage = "usage: zn packet read --packet ID [--from N] [--to N]"; if (args.shift() !== "read") throw new CliError(usage); const id = option(args, "--packet"), rawFrom = option(args, "--from"), rawTo = option(args, "--to"); none(args, usage); if (!id) throw new CliError("--packet is required"); const from = rawFrom === null ? undefined : nonnegative(rawFrom, "--from"), to = rawTo === null ? undefined : nonnegative(rawTo, "--to"); if (to !== undefined && to <= (from ?? 0)) throw new CliError("--to must be greater than --from"); process.stdout.write(await readPacket(config.store, join(state, "packets"), id, from, to)); }
async function threads(config, state, args) { if (args.shift() !== "list") throw new CliError("usage: zn thread list"); none(args, "usage: zn thread list"); const store = await Store.open({ path: config.store, packets: join(state, "packets"), overflowBytes: config.packetOverflowBytes }); try { print(["ID", "UPDATED"], (await store.list()).map((value) => [value.id, String(value.updated)])); } finally { await store.close(); } }

function configText() { return `store "zinc.db"\nturn "turn.md"\ntheme "theme.kdl"\n\nurl "localhost"\nport 5173\nauthor "anonymous"\n\ncompletions-url "http://127.0.0.1:30000/v1/chat/completions"\nparallel 4\ncontext-tokens 32768\ncompact-at 80\nraw-context-bytes 8192\npacket-overflow-bytes 65536\nshell "${process.platform === "win32" ? "pwsh" : "sh"}"\n\nallowlist {\n  git\n  rg\n  find\n  zn\n}\n`; }
function option(args, name) { const index = args.indexOf(name); if (index < 0) return null; if (args.indexOf(name, index + 1) >= 0) throw new CliError(`${name} may only be specified once`); const value = args[index + 1]; if (!value || value.startsWith("--")) throw new CliError(`${name} requires a value`); args.splice(index, 2); return value; }
function flag(args, name) { const index = args.indexOf(name); if (index < 0) return false; if (args.indexOf(name, index + 1) >= 0) throw new CliError(`${name} may only be specified once`); args.splice(index, 1); return true; }
function inside(directory, path) { const value = relative(directory, path); return value === "" || !value.startsWith("..") && !isAbsolute(value); }
function none(args, usage) { if (args.length) throw new CliError(`unexpected argument: ${args[0]}`, usage); }
function positive(value, name) { const number = Number(value); if (!Number.isInteger(number) || number <= 0) throw new CliError(`${name} must be a positive integer`); return number; }
function nonnegative(value, name) { const number = Number(value); if (!Number.isInteger(number) || number < 0) throw new CliError(`${name} must be a non-negative integer`); return number; }
function pid(path) { if (!existsSync(path)) return null; const value = Number(readFileSync(path, "utf8").trim()); return Number.isInteger(value) && value > 0 ? value : null; }
function running(value) { try { process.kill(value, 0); return true; } catch { return false; } }
function line(label, value = "") { process.stdout.write(`${label}${value ? `: ${value}` : ""}\n`); }
function rows(values) { if (!process.stdout.isTTY) return values.forEach(([key, value]) => process.stdout.write(`${key}: ${value}\n`)); const width = Math.max(...values.map(([key]) => key.length)); values.forEach(([key, value]) => process.stdout.write(`  ${key.padEnd(width)}  ${value}\n`)); }
function print(headings, values) { if (!process.stdout.isTTY) return values.forEach((row) => process.stdout.write(`${row.join("\t")}\n`)); const widths = headings.map((heading, index) => Math.max(heading.length, ...values.map((row) => row[index].length))); process.stdout.write(`${headings.map((heading, index) => heading.padEnd(widths[index])).join("  ")}\n`); values.forEach((row) => process.stdout.write(`${row.map((value, index) => value.padEnd(widths[index])).join("  ")}\n`)); }
function help() { process.stdout.write("Zinc\n\n  init | here\n  clean [--here | --user | --thread ID | --packet ID]\n  up | down | status | logs\n  stores | thread list | packet read\n"); }

main().catch((error) => { process.stderr.write(`error: ${error instanceof Error ? error.message : String(error)}\n`); if (error instanceof CliError && error.usage) process.stderr.write(`${error.usage}\n`); process.exitCode = 1; });
