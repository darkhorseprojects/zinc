import { threadContext, encodeThreadBody } from "~/lib/threadBody";
import { openStore, resolveStorePath, loadThreadFromDb, updateThreadBodyFromPacket, addPacket, commitThreadMdx } from "~/lib/db";
import { parse, advance, type AdvanceEntry } from "@darkhorseprojects/circuitry";
import { readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { getZincConfig } from "~/lib/config";
import type { ComponentStatus } from "~/thread/nodes";
import type { ThreadBody, Packet } from "~/lib/types";

export type ContinueRequest = {
  threadId: string;
  input: string;
  mdx?: string;
  baseRevision?: string;
};

export type ContinuationErrorData = {
  stage: string;
  message: string;
  detail?: string;
  command?: string;
  exitCode?: number | null;
  stderr?: string;
};

class ContinuationError extends Error {
  data: ContinuationErrorData;

  constructor(data: ContinuationErrorData) {
    super(data.message);
    this.name = "ContinuationError";
    this.data = data;
  }
}

export function continuationErrorData(error: unknown, fallbackStage = "continuation"): ContinuationErrorData {
  if (error instanceof ContinuationError) return error.data;
  if (error && typeof error === "object" && "data" in error) {
    const data = (error as { data?: unknown }).data;
    if (isContinuationErrorData(data)) return data;
  }
  return { stage: fallbackStage, message: error instanceof Error ? error.message : String(error) };
}

function continuationError(data: ContinuationErrorData): ContinuationError {
  return new ContinuationError(data);
}

export async function continueContext(
  req: ContinueRequest,
  storePath?: string | null,
  onFrame?: (frame: any) => void | Promise<void>,
) {
  const config = await getZincConfig();
  const activeStore = resolveStorePath(storePath || config.store);
  const db = await openStore(activeStore);

  try {
    if (req.mdx !== undefined && req.baseRevision) {
      const saved = await commitThreadMdx(db, req.threadId, req.baseRevision, req.mdx, { packetOverflowBytes: config.packetOverflowBytes });
      if (onFrame) await onFrame({ thread: saved });
      if (!req.input.trim()) return saved;
    }

    let thread = await loadThreadFromDb(db, req.threadId);
    let currentBody: ThreadBody = { ranges: [...thread.body.ranges] };
    let currentPackets: Record<string, Packet> = { ...thread.packets };
    let currentParent: string | null = currentBody.ranges.at(-1)?.packet ?? null;

    async function appendPacket(bytes: string | Uint8Array, author?: "user" | "assistant" | "system") {
      const packet = await addPacket(db, { parent: currentParent, bytes }, { packetOverflowBytes: config.packetOverflowBytes });
      currentParent = packet.id;
      currentPackets[packet.id] = packet;
      currentBody.ranges.push(author ? { packet: packet.id, author } : { packet: packet.id });
      if (onFrame) await onFrame({ packet });
      return packet;
    }

    async function commitBody() {
      const bodyPacket = await addPacket(db, { parent: currentParent, bytes: encodeThreadBody(currentBody) }, { packetOverflowBytes: config.packetOverflowBytes });
      currentParent = bodyPacket.id;
      if (onFrame) await onFrame({ packet: bodyPacket });
      await updateThreadBodyFromPacket(db, req.threadId, bodyPacket.id);
      thread = await loadThreadFromDb(db, req.threadId);
      currentBody = { ranges: [...thread.body.ranges] };
      currentPackets = { ...thread.packets };
      if (onFrame) await onFrame({ thread });
      return thread;
    }

    async function appendDividerIfNeeded(nextAuthor: "user" | "assistant" | "system") {
      const last = currentBody.ranges.at(-1);
      if (last && last.author !== nextAuthor) await appendPacket("\n\n---\n\n");
    }

    if (req.input.trim()) {
      await appendDividerIfNeeded("user");
      await appendPacket(`${req.input}\n\n`, "user");
      await commitBody();
    }

    const turnText = await readFile(config.turn, "utf8");
    const turn = parse(turnText);
    const turnCwd = dirname(config.turn);
    const turnTracker = new Map<string, unknown>();

    while (true) {
      const context = threadContext(currentBody, currentPackets, config.rawContextBytes, activeStore);
      const state: Record<string, unknown> = {
        context,
        shell: config.shell,
        completions: config.completionsUrl,
        cwd: config.zincDir,
      };

      const turnAdvance = await advance(turn.definition, state, turnTracker, {
        cwd: turnCwd,
        env: {
          ...process.env,
          COMPLETIONS_URL: config.completionsUrl,
          ALLOWLIST: config.allowlist.join(" "),
        },
        onOutput: async event => {
          if (onFrame) await onFrame({ output: { entry: event.entry, stream: event.stream, text: event.chunk.toString("utf8") } });
        },
        runSource: async (source, input, runOptions) => {
          if (source === config.shell || source === "$shell") {
            const cmd = typeof input === "string" ? input : (isRecord(input) && typeof input.cmd === "string" ? input.cmd : "");
            if (!cmd) throw new Error("Command is empty");

            const allowlist = config.allowlist;
            const head = cmd.trim().split(/\s+/)[0];
            if (allowlist.length && !allowlist.includes(head)) {
              return {
                stdout: "",
                stderr: `command '${head}' is not in the allowlist. Allowed: ${allowlist.join(", ")}`,
                code: 1,
              };
            }

            const spawnCmd = config.shell;
            const spawnArgs: string[] = [];
            if (spawnCmd === "bun") {
              spawnArgs.push("run", "-e", `import { $ } from 'bun'; const r = await $\`sh -c \${process.env.CMD}\`.quiet().nothrow(); console.log(JSON.stringify({ stdout: r.stdout.toString(), stderr: r.stderr.toString(), code: r.exitCode }));`);
            } else if (spawnCmd === "bash" || spawnCmd === "sh") {
              spawnArgs.push("-c", cmd);
            } else if (spawnCmd.includes("powershell") || spawnCmd.includes("pwsh")) {
              spawnArgs.push("-NoProfile", "-Command", cmd);
            } else {
              spawnArgs.push("-c", cmd);
            }

            const procEnv = { ...process.env, ...runOptions.env, CMD: cmd };
            const { spawn } = await import("node:child_process");
            const child = spawn(spawnCmd, spawnArgs, { cwd: runOptions.cwd, env: procEnv });

            const stdoutBufs: Buffer[] = [];
            const stderrBufs: Buffer[] = [];

            child.stdout.on("data", (chunk: Buffer) => stdoutBufs.push(chunk));
            child.stderr.on("data", (chunk: Buffer) => stderrBufs.push(chunk));

            const exitCode = await new Promise<number | null>((resolveExit, reject) => {
              child.on("error", reject);
              child.on("close", resolveExit);
            });

            const stdoutStr = Buffer.concat(stdoutBufs).toString("utf8");
            const stderrStr = Buffer.concat(stderrBufs).toString("utf8");

            if (spawnCmd === "bun") {
              try {
                return JSON.parse(stdoutStr.trim());
              } catch {}
            }

            return {
              stdout: stdoutStr,
              stderr: stderrStr,
              code: exitCode ?? 0,
            };
          }
          return undefined;
        }
      });

      if (!turnAdvance.progressed) throw continuationError({ stage: "turn.advance", message: "Configured turn did not advance" });
      for (const entry of turnAdvance.entries) {
        if (entry.name === "respond" || entry.source === config.completionsUrl) continue;
        await appendPacket(sourceBlock(entry));
      }

      let lastReasoning = "";
      let lastResponse = "";
      let lastCircuitry = "";
      let lastOutcome: "reasoning" | "response" | "circuitry" | null = null;

      for (const entry of turnAdvance.entries) {
        if (isRecord(entry.bindings)) {
          if (entry.bindings.reasoning !== undefined) {
            lastReasoning = String(entry.bindings.reasoning);
            if (lastOutcome === null) lastOutcome = "reasoning";
          }
          if (entry.bindings.response !== undefined) {
            lastResponse = String(entry.bindings.response);
            lastOutcome = "response";
          }
          if (entry.bindings.circuitry !== undefined) {
            lastCircuitry = String(entry.bindings.circuitry);
            lastOutcome = "circuitry";
          }
        }
      }

      if (!lastOutcome) throw continuationError({ stage: "turn.output", message: "Turn produced no response or circuitry" });

      if (lastOutcome === "response" || lastOutcome === "reasoning") {
        await appendDividerIfNeeded("assistant");
        let packetText = "";
        if (lastReasoning.trim()) {
          packetText += `<Reasoning>\n${lastReasoning.trim()}\n</Reasoning>\n\n`;
        }
        if (lastOutcome === "response") {
          packetText += `${lastResponse}\n\n`;
        }
        await appendPacket(packetText, "assistant");
        return await commitBody();
      }

      if (lastOutcome === "circuitry") {
        const circuitry = lastCircuitry.trim();
        if (!circuitry) throw continuationError({ stage: "turn.circuitry", message: "Circuitry output was empty" });
        await appendPacket(circuitryBlock(circuitry, turnCwd, config.shell));
        await runReturnedCircuitry(circuitry, turnCwd);
        await commitBody();
        continue;
      }
    }

    async function runReturnedCircuitry(circuitry: string, cwd: string) {
      const returned = parse(circuitry);
      const returnedContext = threadContext(currentBody, currentPackets, config.rawContextBytes, activeStore);
      const returnedState: Record<string, unknown> = {
        context: returnedContext,
        shell: config.shell,
        completions: config.completionsUrl,
        cwd: config.zincDir,
      };
      const tracker = new Map<string, unknown>();
      let advanced = false;
      while (true) {
        const result = await advance(returned.definition, returnedState, tracker, {
          cwd,
          env: {
            ...process.env,
            COMPLETIONS_URL: config.completionsUrl,
            ALLOWLIST: config.allowlist.join(" "),
          },
          onOutput: async event => {
            if (onFrame) await onFrame({ output: { entry: event.entry, stream: event.stream, text: event.chunk.toString("utf8") } });
          },
          runSource: async (source, input, runOptions) => {
            if (source === config.shell || source === "$shell") {
              const cmd = typeof input === "string" ? input : (isRecord(input) && typeof input.cmd === "string" ? input.cmd : "");
              if (!cmd) throw new Error("Command is empty");
              const allowlist = config.allowlist;
              const head = cmd.trim().split(/\s+/)[0];
              if (allowlist.length && !allowlist.includes(head)) {
                return {
                  stdout: "",
                  stderr: `command '${head}' is not in the allowlist. Allowed: ${allowlist.join(", ")}`,
                  code: 1,
                };
              }
              const spawnCmd = config.shell;
              const spawnArgs: string[] = [];
              if (spawnCmd === "bun") {
                spawnArgs.push("run", "-e", `import { $ } from 'bun'; const r = await $\`sh -c \${process.env.CMD}\`.quiet().nothrow(); console.log(JSON.stringify({ stdout: r.stdout.toString(), stderr: r.stderr.toString(), code: r.exitCode }));`);
              } else if (spawnCmd === "bash" || spawnCmd === "sh") {
                spawnArgs.push("-c", cmd);
              } else if (spawnCmd.includes("powershell") || spawnCmd.includes("pwsh")) {
                spawnArgs.push("-NoProfile", "-Command", cmd);
              } else {
                spawnArgs.push("-c", cmd);
              }
              const procEnv = { ...process.env, ...runOptions.env, CMD: cmd };
              const { spawn } = await import("node:child_process");
              const child = spawn(spawnCmd, spawnArgs, { cwd: runOptions.cwd, env: procEnv });
              const stdoutBufs: Buffer[] = [];
              const stderrBufs: Buffer[] = [];
              child.stdout.on("data", (chunk: Buffer) => stdoutBufs.push(chunk));
              child.stderr.on("data", (chunk: Buffer) => stderrBufs.push(chunk));
              const exitCode = await new Promise<number | null>((resolveExit, reject) => {
                child.on("error", reject);
                child.on("close", resolveExit);
              });
              const stdoutStr = Buffer.concat(stdoutBufs).toString("utf8");
              const stderrStr = Buffer.concat(stderrBufs).toString("utf8");
              if (spawnCmd === "bun") {
                try {
                  return JSON.parse(stdoutStr.trim());
                } catch {}
              }
              return {
                stdout: stdoutStr,
                stderr: stderrStr,
                code: exitCode ?? 0,
              };
            }
            return undefined;
          }
        });
        if (!result.progressed) break;
        advanced = true;
        for (const entry of result.entries) await appendPacket(sourceBlock(entry));
      }
      if (!advanced) throw continuationError({ stage: "circuitry.advance", message: "Returned Circuitry did not advance", command: circuitry });
    }
  } catch (error) {
    const data = continuationErrorData(error);
    if (onFrame) await onFrame({ error: data });
    const current = await loadThreadFromDb(db, req.threadId);
    const parent = current.body.ranges.at(-1)?.packet ?? null;
    const packet = await addPacket(db, {
      parent,
      bytes: errorMdx({ stage: data.stage, status: "error", label: data.stage.split(".")[0] || "system", body: errorBody(data) }),
    }, { packetOverflowBytes: config.packetOverflowBytes });
    const body: ThreadBody = { ranges: [...current.body.ranges, { packet: packet.id, author: "system" as const }] };
    const bodyPacket = await addPacket(db, { parent: packet.id, bytes: encodeThreadBody(body) }, { packetOverflowBytes: config.packetOverflowBytes });
    await updateThreadBodyFromPacket(db, req.threadId, bodyPacket.id);
    return await loadThreadFromDb(db, req.threadId);
  } finally {
    db.close();
  }
}

function objectToKdl(obj: Record<string, unknown>, indent = 0): string {
  const spaces = " ".repeat(indent);
  return Object.entries(obj)
    .map(([key, val]) => {
      if (val === null || val === undefined) return "";
      if (typeof val === "object") {
        if (Array.isArray(val)) {
          return `${spaces}${key} ${val.map(v => JSON.stringify(v)).join(" ")}`;
        }
        return `${spaces}${key} {\n${objectToKdl(val as Record<string, unknown>, indent + 2)}${spaces}}`;
      }
      return `${spaces}${key} ${JSON.stringify(val)}`;
    })
    .filter(Boolean)
    .join("\n");
}

function sourceBlock(entry: AdvanceEntry): string {
  const output = entry.output;
  if (isRecord(output) && ("code" in output || "exit" in output) && ("stdout" in output || "stderr" in output)) {
    const cmd = typeof entry.input === "string" ? entry.input : (isRecord(entry.input) && typeof entry.input.cmd === "string" ? entry.input.cmd : entry.name);
    const code = typeof output.code === "number" ? output.code : (typeof output.exit === "number" ? output.exit : 0);
    return commandMdx({
      cmd,
      exit: code,
      status: code === 0 ? "ok" : "error",
      label: entry.name,
      body: String(output.stdout || output.stderr || ""),
    });
  }
  return sourceMdx({
    status: "ok",
    label: entry.name,
    body: fenced("kdl", objectToKdl({ source: entry.source, output: entry.output, bindings: entry.bindings })),
  });
}

function circuitryBlock(circuitry: string, loopDir: string, configShell?: string): string {
  try {
    const doc = parse(circuitry);
    const entries = Object.values(doc.definition.entries);
    if (entries.length === 1) {
      const entry = entries[0];
      const source = entry.source;
      const input = entry.in;

      // Extract shell command execution
      if (typeof source === "string" && (source === "$shell" || source === configShell) && (typeof input === "string" || (isRecord(input) && typeof input.cmd === "string"))) {
        const cmd = typeof input === "string" ? input : String(input.cmd);
        return commandMdx({
          cmd,
          exit: null,
          status: "pending",
          label: "execute",
          body: "",
        });
      }

      // Extract zn packet read execution
      if (typeof source === "string" && source === "zn" && isRecord(input) && Array.isArray(input.args)) {
        return commandMdx({
          cmd: ["zn", ...input.args.map(String)].join(" "),
          exit: null,
          status: "pending",
          label: "execute",
          body: "",
        });
      }
    }
  } catch (e) {}

  // Fallback: raw KDL block
  return sourceMdx({
    status: "info",
    label: "circuitry",
    body: fenced("kdl", circuitry),
  });
}



function isContinuationErrorData(value: unknown): value is ContinuationErrorData {
  return typeof value === "object" && value !== null && typeof (value as ContinuationErrorData).stage === "string" && typeof (value as ContinuationErrorData).message === "string";
}

function commandMdx(input: {
  cmd: string;
  exit: number | null;
  status: ComponentStatus;
  label: string;
  body: string;
}) {
  const attributes = [
    `cmd=${JSON.stringify(input.cmd)}`,
    input.exit !== null ? `exit={${input.exit}}` : "",
    `status=${JSON.stringify(input.status)}`,
    input.label ? `label=${JSON.stringify(input.label)}` : "",
  ].filter(Boolean).join(" ");
  return `${[`<Command ${attributes}>`, input.body.trimEnd(), `</Command>`].join("\n")}\n\n`;
}

function errorMdx(input: {
  stage: string;
  status: ComponentStatus;
  label: string;
  body: string;
}) {
  const attributes = [
    input.stage ? `stage=${JSON.stringify(input.stage)}` : "",
    `status=${JSON.stringify(input.status)}`,
    input.label ? `label=${JSON.stringify(input.label)}` : "",
  ].filter(Boolean).join(" ");
  return `${[`<Error ${attributes}>`, input.body.trimEnd(), `</Error>`].join("\n")}\n\n`;
}

function sourceMdx(input: {
  status: ComponentStatus;
  label: string;
  body: string;
}) {
  const attributes = [
    `status=${JSON.stringify(input.status)}`,
    input.label ? `label=${JSON.stringify(input.label)}` : "",
  ].filter(Boolean).join(" ");
  return `${[`<Source ${attributes}>`, input.body.trimEnd(), `</Source>`].join("\n")}\n\n`;
}

function fenced(language: string, body: string) {
  return [`\`\`\`${language}`, body.trimEnd(), "```"].join("\n");
}

function errorBody(error: ContinuationErrorData) {
  return [
    error.message,
    error.detail ? `detail:\n${error.detail}` : "",
    error.stderr ? `stderr:\n${error.stderr}` : "",
  ].filter(Boolean).join("\n\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
