#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { dirname, join, resolve } from "node:path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, openSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir } from "node:os";

const ROOT = resolve(dirname(Bun.main), "..");
const WEB = join(ROOT, "web");

const DEFAULT_TURN_MD = `---
circuitry "0.10.0"

in {
  context $context
  completions $completions
  shell $shell
  cwd $cwd
}

respond source="$completions" {
  in "{\\"messages\\": [{\\"role\\": \\"system\\", \\"content\\": \\"@Instructions\\"}, {\\"role\\": \\"user\\", \\"content\\": \\"$context\\"}]}"
  out "{\\"choices\\": [{\\"message\\": {\\"content\\": \\"?response\\", \\"reasoning_content\\": \\"?reasoning\\"}}]}"
}

out {
  reasoning ?reasoning
  response  ?response
}
---

## Instructions

You are a friendly agent here to help with the user's request.

Your current workspace directory is at $cwd.

### Tool Execution
If you need to perform actions (like running bash commands), return returned circuitry directly in your response:
\`\`\`kdl
circuitry "0.10.0"
run source="$shell" "your command here"
\`\`\`
`;

const DEFAULT_CONFIG_KDL = (storePath, turnPath, zincDir) => `store "${storePath}"
turn "${turnPath}"
zinc-dir "${zincDir}"
raw-context-bytes 8192
packet-overflow-bytes 65536

completions-url "http://127.0.0.1:30000/v1/chat/completions"
shell "bun"

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

function initDb(dbPath) {
  mkdirSync(dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.run("create table if not exists meta (key text primary key, value text not null)");
  db.run("create table if not exists packets (id text primary key, parent text, at integer not null, bytes blob not null)");
  db.run("create table if not exists threads (id text primary key, title text, body text not null, updated integer not null)");
  db.run("insert or replace into meta (key, value) values ('schema_version', '1')");
  db.close();
}

function parseConfig(configPath) {
  if (!existsSync(configPath)) {
    console.error(`config not found: ${configPath}`);
    process.exit(1);
  }
  const base = dirname(configPath);
  const text = readFileSync(configPath, "utf8");
  const values = {};
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("//") || line.endsWith("{") || line === "}") continue;
    const parts = line.split(/\s+/, 2);
    if (parts.length === 2) {
      // Remove surrounding quotes if present
      let val = parts[1];
      if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
      values[parts[0]] = val;
    }
  }

  const zincDir = resolvePath(values["zinc-dir"] || base, base);
  return {
    config: configPath,
    store: resolvePath(values.store || "zinc.db", base),
    turn: resolvePath(values.turn || "turn.md", base),
    zincDir,
    web_pid: join(zincDir, "web.pid"),
    web_log: join(zincDir, "web.log"),
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
    initDb(dbPath);
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
    if (existsSync(config.web_pid)) {
      const pid = parseInt(readFileSync(config.web_pid, "utf8").trim(), 10);
      if (processRunning(pid)) {
        console.log(`zinc web already running pid=${pid}`);
        return;
      }
    }

    mkdirSync(config.zincDir, { recursive: true });
    const logFd = openSync(config.web_log, "a");
    const proc = spawn("bun", [join(WEB, "dist", "server", "index.js")], {
      cwd: WEB,
      env: { ...process.env, ZINC_CONFIG: config.config },
      detached: true,
      stdio: ["ignore", logFd, logFd],
    });
    proc.unref();

    writeFileSync(config.web_pid, String(proc.pid), "utf8");
    console.log(`started zinc web pid=${proc.pid}`);
    console.log(`logs: ${config.web_log}`);
    return;
  }

  if (cmd === "down") {
    if (!existsSync(config.web_pid)) {
      console.log("zinc web is not running");
      return;
    }
    const pid = parseInt(readFileSync(config.web_pid, "utf8").trim(), 10);
    if (processRunning(pid)) {
      process.kill(pid, "SIGTERM");
      let stopped = false;
      for (let i = 0; i < 30; i++) {
        if (!processRunning(pid)) {
          stopped = true;
          break;
        }
        await new Promise(r => setTimeout(r, 100));
      }
      if (!stopped) process.kill(pid, "SIGKILL");
      console.log(`stopped zinc web pid=${pid}`);
    } else {
      console.log("zinc web is not running");
    }
    try { unlinkSync(config.web_pid); } catch {}
    return;
  }

  if (cmd === "status") {
    if (existsSync(config.web_pid)) {
      const pid = parseInt(readFileSync(config.web_pid, "utf8").trim(), 10);
      if (processRunning(pid)) {
        console.log(`running pid=${pid}`);
        return;
      }
    }
    console.log("stopped");
    return;
  }

  if (cmd === "logs") {
    if (!existsSync(config.web_log)) {
      console.log(`no log file: ${config.web_log}`);
      return;
    }
    const text = readFileSync(config.web_log, "utf8");
    const lines = text.split("\n");
    console.log(lines.slice(-200).join("\n"));
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
    const db = new Database(config.store);
    const row = db.query("select bytes from packets where id = $id").get({ $id: packet });
    db.close();
    if (!row) {
      console.error(`packet not found: ${packet}`);
      process.exit(1);
    }
    process.stdout.write(row.bytes);
    return;
  }

  if (cmd === "thread") {
    const sub = args.shift();
    const db = new Database(config.store);
    if (sub === "list") {
      const rows = db.query("select id, title, updated from threads order by updated desc").all();
      for (const row of rows) {
        console.log(`${row.id}\t${row.title || ""}\t${row.updated}`);
      }
    } else if (sub === "read") {
      const thrIdx = args.indexOf("--thread");
      if (thrIdx === -1 || !args[thrIdx + 1]) {
        console.error("--thread is required");
        db.close();
        process.exit(1);
      }
      const thread = args[thrIdx + 1];
      const row = db.query("select body from threads where id = $id").get({ $id: thread });
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
    console.log("zn init|here|clean|up|down|logs|status|packet|thread");
    return;
  }

  console.error(`unknown command: ${cmd}`);
  process.exit(1);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
