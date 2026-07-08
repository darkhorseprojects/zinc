#!/usr/bin/env bun
import { connect } from "@tursodatabase/database";
import { parse as parseKdl } from "kdljs";
import { dirname, join, resolve } from "node:path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, openSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir } from "node:os";

const ROOT = resolve(dirname(Bun.main), "..");
const WEB = join(ROOT, "web");
const DEFAULT_SHELL = process.platform === "win32" ? "pwsh" : "sh";

const DEFAULT_TURN_MD = `---
circuitry "0.10.0"

in {
  context $context
  completions $completions
  shell $shell
  cwd $cwd
}

respond source="$completions" {
  in "{\\"messages\\": [{\\"role\\": \\"system\\", \\"content\\": \\"@Instructions\\"}, {\\"role\\": \\"user\\", \\"content\\": \\"$context\\"}], \\"tools\\": [{\\"type\\": \\"function\\", \\"function\\": {\\"name\\": \\"circuitry\\", \\"description\\": \\"Execute Circuitry KDL.\\", \\"parameters\\": {\\"type\\": \\"object\\", \\"properties\\": {\\"kdl\\": {\\"type\\": \\"string\\", \\"description\\": \\"Complete Circuitry KDL document.\\"}}, \\"required\\": [\\"kdl\\"], \\"additionalProperties\\": false}}}]}"
  out "{\\"circuitry\\": \\"?circuitry\\", \\"choices\\": [{\\"message\\": {\\"content\\": \\"?response\\", \\"reasoning_content\\": \\"?reasoning\\"}}]}"
}

out {
  reasoning ?reasoning
  response  ?response
  circuitry ?circuitry
}
---

## Instructions

You are a friendly and honest assistant here to help the user.

Your current workspace directory is at $cwd.

### How the loop works
If you respond with \`response\` last, zinc counts that as your final response. If you want to respond without ending the turn (continuing to reason/work), do not put your response last in each output.

### Tool Execution
Use the \`circuitry\` tool for actions. It has one parameter: \`kdl\` (a string containing a complete Circuitry document). Zinc executes every \`circuitry\` tool call.

For shell commands, use \`$shell\` with \`-c\`:
\`\`\`kdl
circuitry "0.10.0"
run source="$shell" "-c" "your command here"
\`\`\`

### Context References
Older context may be referenced as \`- packet_id\` or \`- packet_id from:to\`. To inspect one, call the \`circuitry\` tool with kdl that runs: \`zn packet read --packet packet_id\`.

### Response Format
Your \`response\` renders as MDX. You may emit \`<Reasoning>\`, \`<Shell cmd="...">\`, \`<Error>\`, \`<Source>\`, or any custom \`<Tag prop="x">body</Tag>\`. Known tags render as interactive components; unknown tags render as raw editable blocks. Use this to structure rich responses.

Navigate the conversation and read prior context before responding. Trace the tail of useful information. Feel the structure and pacing.
`;

const DEFAULT_CONFIG_KDL = (storePath, turnPath, zincDir) => `store "${storePath}"
turn "${turnPath}"
zinc-dir "${zincDir}"
raw-context-bytes 8192
packet-overflow-bytes 65536

completions-url "http://127.0.0.1:30000/v1/chat/completions"
shell "${DEFAULT_SHELL}"

allowlist {
  git
  ls
  grep
  zn
  npm
  danger {
    rm
    mv
  }
}
`;

function defaultZincHome() {
  if (process.env.ZINC_HOME) return resolve(process.env.ZINC_HOME);
  if (process.platform === "win32") return join(process.env.APPDATA || homedir(), "Zinc");
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "Zinc");
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "zinc");
}

function resolvePath(p, base) {
  const expanded = p.replace(/^~(?=$|\/)/, homedir());
  return resolve(base, expanded);
}

async function initDb(dbPath) {
  mkdirSync(dirname(dbPath), { recursive: true });
  const db = await connect(dbPath);
  await (await db.prepare("create table if not exists meta (key text primary key, value text not null)")).run();
  await (await db.prepare("create table if not exists packets (id text primary key, parent text, at integer not null, bytes blob not null)")).run();
  await (await db.prepare("create table if not exists threads (id text primary key, title text, body text not null, updated integer not null)")).run();
  await (await db.prepare("insert or replace into meta (key, value) values ('schema_version', '1')")).run();
  db.close();
}

function nodeToValue(node) {
  const children = node.children ?? [];
  if (children.length) return Object.fromEntries(children.map((child) => [child.name, nodeToValue(child)]));
  const args = node.values ?? [];
  if (args.length === 0) return true;
  if (args.length === 1) return String(args[0]);
  return args.map(String);
}

function parseConfig(configPath) {
  if (!existsSync(configPath)) {
    console.error(`config not found: ${configPath}`);
    process.exit(1);
  }
  const base = dirname(configPath);
  const parsed = parseKdl(readFileSync(configPath, "utf8"));
  if (parsed.errors?.length) {
    console.error(`config KDL parse error: ${parsed.errors.map((e) => e.message).join(", ")}`);
    process.exit(1);
  }
  const values = Object.fromEntries((parsed.output ?? []).map((node) => [node.name, nodeToValue(node)]));
  const zincDir = resolvePath(String(values["zinc-dir"] ?? base), base);

  return {
    config: configPath,
    store: resolvePath(String(values.store ?? "zinc.db"), base),
    turn: resolvePath(String(values.turn ?? "turn.md"), base),
    zincDir,
    webPid: join(zincDir, "web.pid"),
    webLog: join(zincDir, "web.log"),
  };
}

function processRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function storesJsonlPath(zincDir) {
  return join(zincDir, "stores.jsonl");
}

async function readStores(zincDir) {
  const path = await storesJsonlPath(zincDir);
  if (!existsSync(path)) return [];
  const lines = readFileSync(path, "utf8").split(/\r?\n/).filter((line) => line.trim());
  return lines.map((line) => JSON.parse(line));
}

async function main() {
  const args = [...process.argv.slice(2)];
  const cmd = args.shift() || "help";

  if (cmd === "clean") {
    const isGlobal = args.includes("--global");
    const isAll = args.includes("--all");

    const deletePath = (p) => {
      if (existsSync(p)) {
        rmSync(p, { recursive: true, force: true });
        console.log(`deleted: ${p}`);
      }
    };

    if (isAll) {
      deletePath(resolve(".zinc"));
      deletePath(defaultZincHome());
      deletePath(join(homedir(), ".local", "lib", "zinc"));
      deletePath(join(homedir(), ".local", "bin", "zn"));
      console.log("uninstalled zinc fully");
      return;
    }

    if (isGlobal) {
      deletePath(defaultZincHome());
      return;
    }

    const localZinc = resolve(".zinc");
    if (existsSync(localZinc)) {
      deletePath(localZinc);
    } else {
      console.log("No local .zinc folder found. Use zn clean --global to clean user config.");
    }
    return;
  }

  if (cmd === "init" || cmd === "here") {
    const home = cmd === "here" ? resolve(".zinc") : defaultZincHome();
    const configPath = join(home, "config.kdl");
    const turnPath = join(home, "turn.md");
    const dbPath = join(home, "zinc.db");

    mkdirSync(home, { recursive: true });
    await initDb(dbPath);
    console.log(`initialized db: ${dbPath}`);

    if (!existsSync(turnPath)) {
      writeFileSync(turnPath, DEFAULT_TURN_MD, "utf8");
      console.log(`wrote turn template: ${turnPath}`);
    }
    if (!existsSync(configPath)) {
      writeFileSync(configPath, DEFAULT_CONFIG_KDL("zinc.db", "turn.md", "."), "utf8");
      console.log(`wrote config: ${configPath}`);
    }
    console.log(`Edit config in ${home}`);
    return;
  }

  const configArg = args.includes("--config") ? args[args.indexOf("--config") + 1] : null;
  const configPath = configArg ? resolve(configArg) : join(defaultZincHome(), "config.kdl");
  const config = parseConfig(configPath);

  if (cmd === "up") {
    if (existsSync(config.webPid)) {
      const pid = parseInt(readFileSync(config.webPid, "utf8").trim(), 10);
      if (processRunning(pid)) {
        console.log(`zinc web already running pid=${pid}`);
        return;
      }
    }

    mkdirSync(config.zincDir, { recursive: true });
    const logFd = openSync(config.webLog, "a");
    const proc = spawn("bun", [join(WEB, "dist", "server", "index.js")], {
      cwd: WEB,
      env: { ...process.env, ZINC_CONFIG: config.config },
      detached: true,
      stdio: ["ignore", logFd, logFd],
    });
    proc.unref();

    writeFileSync(config.webPid, String(proc.pid), "utf8");
    console.log(`started zinc web pid=${proc.pid}`);
    console.log(`logs: ${config.webLog}`);
    return;
  }

  if (cmd === "down") {
    if (!existsSync(config.webPid)) {
      console.log("zinc web is not running");
      return;
    }
    const pid = parseInt(readFileSync(config.webPid, "utf8").trim(), 10);
    if (processRunning(pid)) {
      process.kill(pid, "SIGTERM");
      let stopped = false;
      for (let i = 0; i < 30; i++) {
        if (!processRunning(pid)) {
          stopped = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 100));
      }
      if (!stopped) process.kill(pid, "SIGKILL");
      console.log(`stopped zinc web pid=${pid}`);
    } else {
      console.log("zinc web is not running");
    }
    try {
      unlinkSync(config.webPid);
    } catch {}
    return;
  }

  if (cmd === "status") {
    if (existsSync(config.webPid)) {
      const pid = parseInt(readFileSync(config.webPid, "utf8").trim(), 10);
      if (processRunning(pid)) {
        console.log(`running pid=${pid}`);
        return;
      }
    }
    console.log("stopped");
    return;
  }

  if (cmd === "logs") {
    if (!existsSync(config.webLog)) {
      console.log(`no log file: ${config.webLog}`);
      return;
    }
    const text = readFileSync(config.webLog, "utf8");
    const lines = text.split("\n");
    console.log(lines.slice(-200).join("\n"));
    return;
  }

  if (cmd === "stores") {
    const stores = await readStores(config.zincDir);
    for (const store of stores) console.log(`${store.path}\t${store.name || ""}`);
    return;
  }

  if (cmd === "packet") {
    const sub = args.shift();
    if (sub !== "read") {
      console.error("usage: zn packet read --packet ID");
      process.exit(1);
    }
    const pktIdx = args.indexOf("--packet");
    if (pktIdx === -1 || !args[pktIdx + 1]) {
      console.error("--packet is required");
      process.exit(1);
    }
    const packet = args[pktIdx + 1];
    const db = await connect(config.store);
    const row = await (await db.prepare("select bytes from packets where id = ?")).get(packet);
    db.close();
    if (!row) {
      console.error(`packet not found: ${packet}`);
      process.exit(1);
    }
    process.stdout.write(Buffer.from(row.bytes));
    return;
  }

  if (cmd === "thread") {
    const sub = args.shift();
    const db = await connect(config.store);
    if (sub === "list") {
      const rows = await (await db.prepare("select id, title, updated from threads order by updated desc")).all();
      for (const row of rows) console.log(`${row.id}\t${row.title || ""}\t${row.updated}`);
    } else if (sub === "read") {
      const thrIdx = args.indexOf("--thread");
      if (thrIdx === -1 || !args[thrIdx + 1]) {
        console.error("--thread is required");
        db.close();
        process.exit(1);
      }
      const thread = args[thrIdx + 1];
      const row = await (await db.prepare("select body from threads where id = ?")).get(thread);
      if (!row) {
        console.error(`thread not found: ${thread}`);
        db.close();
        process.exit(1);
      }
      console.log(row.body);
    } else {
      console.error("usage: zn thread list|read");
      db.close();
      process.exit(1);
    }
    db.close();
    return;
  }

  if (cmd === "help") {
    console.log("zn init|here|clean|up|down|logs|status|stores|packet|thread");
    return;
  }

  console.error(`unknown command: ${cmd}`);
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
