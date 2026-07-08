import { threadContext } from "~/lib/context";
import { encodeThreadBody } from "~/lib/threadBody";
import { openStore, resolveStorePath, loadThreadFromDb, updateThreadBodyFromPacket, addPacket, commitThreadMdx } from "~/lib/db";
import { parse, advance, type AdvanceEntry, type RunSourceContext } from "@darkhorseprojects/circuitry";
import { readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { getZincConfig, type ZincConfig } from "~/lib/config";
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
  stderr?: string;
};

type Author = "user" | "assistant" | "system";

class ContinuationError extends Error {
  constructor(readonly data: ContinuationErrorData) {
    super(data.message);
    this.name = "ContinuationError";
  }
}

export function continuationErrorData(error: unknown, fallbackStage = "continuation"): ContinuationErrorData {
  if (error instanceof ContinuationError) return error.data;
  if (error && typeof error === "object" && "data" in error && isContinuationErrorData((error as { data?: unknown }).data)) {
    return (error as { data: ContinuationErrorData }).data;
  }
  return { stage: fallbackStage, message: error instanceof Error ? error.message : String(error) };
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

    async function appendPacket(bytes: string | Uint8Array, author?: Author) {
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

    async function appendDividerIfNeeded(nextAuthor: Author) {
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
    const runOptions = advanceOptions(config, onFrame);

    while (true) {
      const state = loopState(config, currentBody, currentPackets);
      const turnAdvance = await advance(turn.definition, state, turnTracker, { ...runOptions, cwd: turnCwd });

      if (!turnAdvance.progressed) throw continuationError({ stage: "turn.advance", message: "Configured turn did not advance" });
      for (const entry of turnAdvance.entries) {
        if (entry.name === "respond" || entry.source === config.completionsUrl) continue;
        await appendPacket(sourceBlock(entry));
      }

      const outcome = terminalBinding(turnAdvance.entries.at(-1));
      if (!outcome) throw continuationError({ stage: "turn.output", message: "Turn produced no reasoning, response, or circuitry" });

      if (outcome.kind === "response") {
        await appendDividerIfNeeded("assistant");
        await appendPacket(responseMdx(outcome), "assistant");
        return await commitBody();
      }

      if (outcome.kind === "continue") {
        await appendDividerIfNeeded("assistant");
        await appendPacket(responseMdx(outcome), "assistant");
        await commitBody();
        continue;
      }

      const circuitries = outcome.circuitry.map((kdl) => kdl.trim()).filter(Boolean);
      if (!circuitries.length) throw continuationError({ stage: "turn.circuitry", message: "Circuitry output was empty" });
      for (const circuitry of circuitries) {
        await appendPacket(sourceMdx({ status: "info", label: "circuitry", body: fenced("kdl", circuitry) }));
        await runReturnedCircuitry(circuitry, turnCwd);
      }
      await commitBody();
    }

    async function runReturnedCircuitry(circuitry: string, cwd: string) {
      const returned = parse(circuitry);
      const tracker = new Map<string, unknown>();
      let advanced = false;
      while (true) {
        const state = loopState(config, currentBody, currentPackets);
        const result = await advance(returned.definition, state, tracker, { ...runOptions, cwd });
        if (!result.progressed) break;
        advanced = true;
        for (const entry of result.entries) await appendPacket(sourceBlock(entry));
      }
      if (!advanced) throw continuationError({ stage: "circuitry.advance", message: "Returned Circuitry did not advance" });
    }
  } catch (error) {
    await recordError(db, req.threadId, continuationErrorData(error), config);
    return await loadThreadFromDb(db, req.threadId);
  } finally {
    db.close();
  }
}

type TerminalOutcome =
  | { kind: "response"; response: string; reasoning: string }
  | { kind: "circuitry"; circuitry: string[] }
  | { kind: "continue"; response: string; reasoning: string };

/** Only the last terminal binding in the source output decides: `response` stops; `circuitry` and `reasoning` continue. */
function terminalBinding(last: AdvanceEntry | undefined): TerminalOutcome | null {
  const bindings = last && isRecord(last.bindings) ? last.bindings : {};
  const terminal = last?.bindingOrder.filter((name) => name === "reasoning" || name === "response" || name === "circuitry").at(-1);
  if (terminal === "response") return { kind: "response", response: String(bindings.response), reasoning: bindings.reasoning !== undefined ? String(bindings.reasoning) : "" };
  if (terminal === "circuitry") return { kind: "circuitry", circuitry: (Array.isArray(bindings.circuitry) ? bindings.circuitry : [bindings.circuitry]).map(String) };
  if (terminal === "reasoning") return { kind: "continue", response: bindings.response !== undefined ? String(bindings.response) : "", reasoning: String(bindings.reasoning) };
  return null;
}

function loopState(config: ZincConfig, body: ThreadBody, packets: Record<string, Packet>): Record<string, unknown> {
  return {
    context: threadContext(body, packets, config.rawContextBytes),
    shell: config.shell,
    completions: config.completionsUrl,
    cwd: config.zincDir,
  };
}

/** Host policy: only the configured shell is allowlist-gated (it is the model's one path to running arbitrary commands via returned circuitry). Turn-declared sources, HTTP, and nested documents are trusted by the host and pass through untouched. */
function advanceOptions(config: ZincConfig, onFrame?: (frame: any) => void | Promise<void>) {
  const shellName = config.shell.split(/[\\/]/).pop() ?? config.shell;
  return {
    env: { ...process.env },
    onOutput: async (event: { entry: string; stream: "stdout" | "stderr"; chunk: Buffer }) => {
      if (onFrame) await onFrame({ output: { entry: event.entry, stream: event.stream, text: event.chunk.toString("utf8") } });
    },
    runSource: async (source: string, _input: unknown, context: RunSourceContext) => {
      if (!config.allowlist.length) return undefined;
      const head = source.split(/[\\/]/).pop() ?? source;
      if (head !== shellName) return undefined;
      const cmd = context.argv.find((arg) => !arg.startsWith("-"));
      const cmdHead = cmd?.trim().split(/\s+/)[0];
      if (!cmdHead || config.allowlist.includes(cmdHead)) return undefined;
      throw new Error(`command '${cmdHead}' is not in the allowlist. Allowed: ${config.allowlist.join(", ")}`);
    },
  };
}

async function recordError(db: Awaited<ReturnType<typeof openStore>>, threadId: string, data: ContinuationErrorData, config: ZincConfig) {
  const current = await loadThreadFromDb(db, threadId);
  const parent = current.body.ranges.at(-1)?.packet ?? null;
  const packet = await addPacket(db, {
    parent,
    bytes: errorMdx({ stage: data.stage, label: data.stage.split(".")[0] || "system", body: errorBody(data) }),
  }, { packetOverflowBytes: config.packetOverflowBytes });
  const body: ThreadBody = { ranges: [...current.body.ranges, { packet: packet.id, author: "system" }] };
  const bodyPacket = await addPacket(db, { parent: packet.id, bytes: encodeThreadBody(body) }, { packetOverflowBytes: config.packetOverflowBytes });
  await updateThreadBodyFromPacket(db, threadId, bodyPacket.id);
}

function continuationError(data: ContinuationErrorData): ContinuationError {
  return new ContinuationError(data);
}

function isContinuationErrorData(value: unknown): value is ContinuationErrorData {
  return typeof value === "object" && value !== null && typeof (value as ContinuationErrorData).stage === "string" && typeof (value as ContinuationErrorData).message === "string";
}

function sourceBlock(entry: AdvanceEntry): string {
  const output = entry.output;
  if (isRecord(output) && "code" in output && ("stdout" in output || "stderr" in output)) {
    const cmd = typeof entry.input === "string" ? entry.input : entry.name;
    const code = typeof output.code === "number" ? output.code : 0;
    return commandMdx({ cmd, exit: code, status: code === 0 ? "ok" : "error", label: entry.name, body: String(output.stdout || output.stderr || "") });
  }
  return sourceMdx({ status: "ok", label: entry.name, body: fenced("json", JSON.stringify({ source: entry.source, output: entry.output, bindings: entry.bindings }, null, 2)) });
}

function responseMdx(outcome: { response: string; reasoning: string }): string {
  const reasoning = outcome.reasoning.trim() ? `<Reasoning>\n${outcome.reasoning.trim()}\n</Reasoning>\n\n` : "";
  return `${reasoning}${outcome.response}\n\n`;
}

function commandMdx(input: { cmd: string; exit: number; status: "ok" | "error"; label: string; body: string }) {
  const attributes = [`cmd=${JSON.stringify(input.cmd)}`, `exit={${input.exit}}`, `status=${JSON.stringify(input.status)}`, `label=${JSON.stringify(input.label)}`].join(" ");
  return `<Shell ${attributes}>\n${input.body.trimEnd()}\n</Shell>\n\n`;
}

function errorMdx(input: { stage: string; label: string; body: string }) {
  const attributes = [`stage=${JSON.stringify(input.stage)}`, `status="error"`, `label=${JSON.stringify(input.label)}`].join(" ");
  return `<Error ${attributes}>\n${input.body.trimEnd()}\n</Error>\n\n`;
}

function sourceMdx(input: { status: string; label: string; body: string }) {
  const attributes = [`status=${JSON.stringify(input.status)}`, `label=${JSON.stringify(input.label)}`].join(" ");
  return `<Source ${attributes}>\n${input.body.trimEnd()}\n</Source>\n\n`;
}

function fenced(language: string, body: string) {
  return [`\`\`\`${language}`, body.trimEnd(), "```"].join("\n");
}

function errorBody(error: ContinuationErrorData) {
  return [error.message, error.detail ? `detail:\n${error.detail}` : "", error.stderr ? `stderr:\n${error.stderr}` : ""].filter(Boolean).join("\n\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
