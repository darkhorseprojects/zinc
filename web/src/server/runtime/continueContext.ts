import { threadContext, encodeThreadBody } from "~/lib/threadBody";
import { openStore, resolveStorePath, loadThreadFromDb, updateThreadBodyFromPacket, addPacket, commitThreadMdx } from "~/lib/db";
import { parse, advance, type AdvanceEntry } from "@darkhorseprojects/circuitry";
import { readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { getZincConfig } from "~/lib/config";
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
        cwd: process.cwd(),
        store: activeStore,
        "loop-dir": turnCwd,
        python: config.python,
      };

      const turnAdvance = await advance(turn.definition, state, turnTracker, {
        cwd: turnCwd,
        onOutput: async event => {
          if (onFrame) await onFrame({ output: { entry: event.entry, stream: event.stream, text: event.chunk.toString("utf8") } });
        },
      });

      if (!turnAdvance.progressed) throw continuationError({ stage: "turn.advance", message: "Configured turn did not advance" });
      for (const entry of turnAdvance.entries) await appendPacket(transcriptBlockMdx(sourceBlock(entry)));

      const last = lastRecognizable(turnAdvance.entries);
      if (!last) throw continuationError({ stage: "turn.output", message: "Turn produced no response or circuitry" });

      if (last.name === "response") {
        await appendDividerIfNeeded("assistant");
        await appendPacket(`${String(last.value)}\n\n`, "assistant");
        return await commitBody();
      }

      if (last.name === "circuitry") {
        const circuitry = String(last.value ?? "").trim();
        if (!circuitry) throw continuationError({ stage: "turn.circuitry", message: "Circuitry output was empty" });
        await appendPacket(transcriptBlockMdx({ kind: "source", status: "info", label: "circuitry", body: fenced("kdl", circuitry) }));
        await runReturnedCircuitry(circuitry, turnCwd);
        await commitBody();
        continue;
      }

      if (last.name === "reasoning") {
        throw continuationError({ stage: "turn.output", message: "Turn ended with reasoning but no response or circuitry" });
      }
    }

    async function runReturnedCircuitry(circuitry: string, cwd: string) {
      const returned = parse(circuitry);
      const returnedContext = threadContext(currentBody, currentPackets, config.rawContextBytes, activeStore);
      const returnedState: Record<string, unknown> = {
        context: returnedContext,
        cwd: process.cwd(),
        store: activeStore,
        "loop-dir": cwd,
        python: config.python,
      };
      const tracker = new Map<string, unknown>();
      let advanced = false;
      while (true) {
        const result = await advance(returned.definition, returnedState, tracker, {
          cwd,
          onOutput: async event => {
            if (onFrame) await onFrame({ output: { entry: event.entry, stream: event.stream, text: event.chunk.toString("utf8") } });
          },
        });
        if (!result.progressed) break;
        advanced = true;
        for (const entry of result.entries) await appendPacket(transcriptBlockMdx(sourceBlock(entry)));
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
      bytes: transcriptBlockMdx({ kind: "error", status: "error", label: data.stage.split(".")[0] || "system", stage: data.stage, command: data.command, exit: data.exitCode, body: errorBody(data) }),
    }, { packetOverflowBytes: config.packetOverflowBytes });
    const body: ThreadBody = { ranges: [...current.body.ranges, { packet: packet.id, author: "system" as const }] };
    const bodyPacket = await addPacket(db, { parent: packet.id, bytes: encodeThreadBody(body) }, { packetOverflowBytes: config.packetOverflowBytes });
    await updateThreadBodyFromPacket(db, req.threadId, bodyPacket.id);
    return await loadThreadFromDb(db, req.threadId);
  } finally {
    db.close();
  }
}

function sourceBlock(entry: AdvanceEntry) {
  return {
    kind: "source" as const,
    status: "ok" as const,
    label: entry.name,
    body: fenced("json", JSON.stringify({ source: entry.source, output: entry.output, bindings: entry.bindings }, null, 2)),
  };
}

function lastRecognizable(entries: AdvanceEntry[]) {
  let last: { name: "reasoning" | "response" | "circuitry"; value: unknown } | null = null;
  for (const entry of entries) {
    if (isRecord(entry.output)) {
      for (const [name, value] of Object.entries(entry.output)) {
        if (name === "reasoning" || name === "response" || name === "circuitry") last = { name, value };
      }
    }
    for (const [name, value] of Object.entries(entry.bindings)) {
      if (name === "reasoning" || name === "response" || name === "circuitry") last = { name, value };
    }
  }
  return last;
}

function isContinuationErrorData(value: unknown): value is ContinuationErrorData {
  return typeof value === "object" && value !== null && typeof (value as ContinuationErrorData).stage === "string" && typeof (value as ContinuationErrorData).message === "string";
}

function transcriptBlockMdx(input: {
  kind: "source" | "error" | "note";
  status: "ok" | "error" | "pending" | "info";
  label: string;
  body: string;
  command?: string;
  stage?: string;
  exit?: number | null;
}) {
  const attributes = [
    `kind=${JSON.stringify(input.kind)}`,
    `status=${JSON.stringify(input.status)}`,
    `label=${JSON.stringify(input.label)}`,
    input.command ? `command=${JSON.stringify(input.command)}` : "",
    input.stage ? `stage=${JSON.stringify(input.stage)}` : "",
    input.exit !== undefined && input.exit !== null ? `exit={${input.exit}}` : "",
  ].filter(Boolean).join(" ");
  return `${[`<TranscriptBlock ${attributes}>`, input.body.trimEnd(), `</TranscriptBlock>`].join("\n")}\n\n`;
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
