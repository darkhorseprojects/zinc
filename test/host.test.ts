import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, it } from "node:test";
import { parse } from "@darkhorseprojects/circuitry";
import { BusyError, ZincHost, type Event } from "../src/host.js";
import type { Config } from "../src/config.js";

const roots: string[] = [], servers: Server[] = [], encoder = new TextEncoder(), decoder = new TextDecoder();
afterEach(async () => { await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))); await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });
async function fixture(options: { turn?: string; completionsUrl?: string; allowlist?: string[]; contextTokens?: number; compactAt?: number; rawContextBytes?: number } = {}) { const root = await mkdtemp(join(tmpdir(), "zinc-host-")); roots.push(root); const turn = join(root, "turn.md"); await writeFile(turn, options.turn ?? `in { context $context }\nrespond source="" { (json)in #"{\"type\":\"response.output_text.delta\",\"delta\":\"done\"}"#; (json)out ?provider-event }\nout { provider-event ?provider-event }\n`); const config: Config = { store: join(root, "zinc.db"), turn, theme: join(process.cwd(), "defaults", "theme.kdl"), url: "localhost", port: 5173, author: "anonymous", completionsUrl: options.completionsUrl ?? "http://127.0.0.1:30000/v1/responses", parallel: 2, rawContextBytes: options.rawContextBytes ?? 8192, contextTokens: options.contextTokens ?? 32768, compactAt: options.compactAt ?? 80, packetOverflowBytes: 65536, shell: "sh", allowlist: options.allowlist ?? [] }; return { root, host: await ZincHost.open(config, root) }; }
const providerTurn = `in { context $context; completions-url $completions-url }
respond source="$completions-url" { (json)in { stream #true; context $context }; (json)out ?provider-event }
out { provider-event ?provider-event }
`;
const packet = (text: string) => encoder.encode(`${JSON.stringify({ zinc: "text", format: "markdown", text })}\n`);
const patch = (revision: string, text = "hello") => ({ revision, order: ["user"], writes: [{ id: "user", origins: [], bytes: packet(text) }] });

describe("ZincHost v8", () => {
  it("uses configured Runtime capacity and completes one atomic patch", async () => {
    const { host } = await fixture();
    assert.equal(host.runtime.parallel, 2);
    const created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision));
    await nextType(reader, "done");
    assert.ok((await host.manifest(host.config.store, created.id)).blocks.some((block) => block.role === "agent"));
    await host.close();
  });

  it("streams transient output and commits durable blocks only after HTTP EOF", async () => {
    let ended = false;
    const server = createServer(async (_request, response) => { response.writeHead(200, { "content-type": "text/event-stream" }); response.write('data: {"type":"response.reasoning_text.delta","delta":"thinking "}\n\n'); await delay(20); response.write('data: {"type":"response.output_text.delta","delta":"hello "}\n\n'); await delay(40); ended = true; response.end('data: {"type":"response.output_text.delta","delta":"world"}\n\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}}\n\n'); });
    const url = await listen(server), { host } = await fixture({ turn: providerTurn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision));
    assert.equal((await nextType(reader, "reasoning")).text, "thinking ");
    assert.equal(ended, false);
    assert.equal((await nextType(reader, "response")).text, "hello ");
    await nextType(reader, "done");
    assert.equal(ended, true);
    assert.equal((await host.manifest(host.config.store, created.id)).blocks.filter((block) => block.role === "agent").length, 2);
    await host.close();
  });

  it("keeps packet identities out of raw provider context", async () => {
    const requests: string[] = [];
    const server = createServer(async (request, response) => { requests.push(await requestText(request)); response.writeHead(200, { "content-type": "text/event-stream" }); response.end(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "finished" })}\n\ndata: ${JSON.stringify({ type: "response.completed", response: { usage: { input_tokens: 11, output_tokens: 3, total_tokens: 14 } } })}\n\n`); });
    const url = await listen(server), turn = await readFile(join(process.cwd(), "agent", "turn.md"), "utf8"), { host } = await fixture({ turn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision, "context"));
    await nextType(reader, "done");
    assert.doesNotMatch(requests[0], /pkt_/);
    assert.match(requests[0], /### user/);
    await host.close();
  });

  it("stores nested action results and continues", async () => {
    const requests: string[] = [];
    const server = createServer(async (request, response) => { requests.push(await requestText(request)); response.writeHead(200, { "content-type": "text/event-stream" }); response.end(requests.length === 1 ? `data: ${JSON.stringify({ type: "response.output_item.done", item: { type: "function_call", name: "circuitry", arguments: JSON.stringify({ kdl: 'out { result "ok" }' }) } })}\n\n` : `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "finished" })}\n\n`); });
    const url = await listen(server), { host } = await fixture({ turn: providerTurn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision));
    await nextType(reader, "done");
    assert.equal(requests.length, 2);
    assert.match(JSON.parse(requests[1]).context, /"result": "ok"/);
    await host.close();
  });

  it("runs configured compaction directly after a terminal response", async () => {
    const requests: any[] = [];
    const server = createServer(async (incoming, response) => {
      const request = JSON.parse(await requestText(incoming)); requests.push(request);
      if (request.stream === false) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ output: [{ type: "function_call", name: "apply_compaction", arguments: JSON.stringify({ decisions: [{ action: "keep", indexes: [0], rank: 1 }, { action: "keep", indexes: [1], rank: .8 }] }) }], usage: { input_tokens: 12, output_tokens: 4, total_tokens: 16 } }));
      } else {
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "finished" })}\n\ndata: ${JSON.stringify({ type: "response.completed", response: { usage: { input_tokens: 90, output_tokens: 10, total_tokens: 100 } } })}\n\n`);
      }
    });
    const url = await listen(server), { root, host } = await fixture({ turn: providerTurn, completionsUrl: url, contextTokens: 100, compactAt: 80 });
    await mkdir(join(root, "definitions"), { recursive: true }); await writeFile(join(root, "definitions", "compact.md"), await readFile(join(process.cwd(), "agent", "definitions", "compact.md")));
    const created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision)); await nextType(reader, "done");
    assert.equal(requests.length, 2); assert.equal(requests[0].stream, true); assert.equal(requests[1].stream, false); assert.equal(requests[1].tools[0].name, "apply_compaction");
    await host.close(); const store = await import("../src/store.js").then(({ Store }) => Store.open({ path: host.config.store, packets: join(root, "packets"), overflowBytes: 65536 }));
    assert.equal((await store.state(created.id)).promptTokens, 0); await store.close();
  });

  it("runs the compact definition against the Responses API contract", async () => {
    let request: any;
    const server = createServer(async (incoming, response) => {
      request = JSON.parse(await requestText(incoming));
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ output: [{ type: "function_call", name: "apply_compaction", arguments: JSON.stringify({ decisions: [{ action: "keep", indexes: [0], rank: .9 }] }) }], usage: { input_tokens: 12, output_tokens: 4, total_tokens: 16 } }));
    });
    const url = await listen(server), { host } = await fixture(), program = parse(await readFile(join(process.cwd(), "agent", "definitions", "compact.md"), "utf8"));
    const run = host.runtime.start(program, { candidates: [{ packet: "pkt_a" }], context: "hello", "completions-url": url, "token-limit": 100, "compact-at": 80, "tokens-left": 20 });
    while (await run.advance()) {}
    assert.equal(request.stream, false);
    assert.equal(request.tools[0].name, "apply_compaction");
    assert.deepEqual(request.tool_choice, { type: "function", name: "apply_compaction" });
    assert.deepEqual(run.output().value, { compaction: [{ action: "keep", indexes: [0], rank: .9 }], "prompt-tokens": 12, "completion-tokens": 4, "used-tokens": 16 });
    await host.close();
  });

  it("turns failed and incomplete Responses events into durable errors", async () => {
    for (const event of [{ type: "response.failed", response: { error: { message: "model failed" } } }, { type: "response.incomplete", response: { incomplete_details: { reason: "max_output_tokens" } } }]) {
      const server = createServer((_request, response) => { response.writeHead(200, { "content-type": "text/event-stream" }); response.end(`data: ${JSON.stringify(event)}\n\n`); });
      const url = await listen(server), { host } = await fixture({ turn: providerTurn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
      await host.complete(host.config.store, created.id, patch(created.manifest.revision));
      assert.match((await nextType(reader, "error")).text, /failed|max_output_tokens/);
      await host.close();
    }
  });

  it("publishes catalog changes for fork membership", async () => {
    const { host } = await fixture(), created = await host.create(host.config.store);
    const saved = await host.commit(host.config.store, created.id, patch(created.manifest.revision));
    const reader = host.events(new AbortController().signal).getReader();
    await host.fork(host.config.store, created.id, saved.manifest.revision, "user");
    assert.equal((await nextType(reader, "catalog")).store, host.config.store);
    await host.close();
  });

  it("cancels active completion without persisting an error", async () => {
    let begin!: () => void;
    const started = new Promise<void>((resolve) => { begin = resolve; }), server = createServer((request, response) => { response.writeHead(200, { "content-type": "text/event-stream" }); response.flushHeaders(); begin(); request.once("close", () => response.end()); });
    const url = await listen(server), { host } = await fixture({ turn: providerTurn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision));
    await started;
    await assert.rejects(host.commit(host.config.store, created.id, { revision: (await host.manifest(host.config.store, created.id)).revision, order: ["user"], writes: [] }), BusyError);
    assert.equal(host.cancel(host.config.store, created.id), true);
    await nextType(reader, "done");
    const manifest = await host.manifest(host.config.store, created.id), blocks = await host.blocks(host.config.store, created.id, manifest.revision, manifest.blocks.map((block) => block.id));
    assert.equal(blocks.some((block) => decoder.decode(block.bytes).includes('"format":"error"')), false);
    await host.close();
  });

  it("treats provider sentinels as invalid JSON data", async () => {
    const server = createServer((_request, response) => { response.writeHead(200, { "content-type": "text/event-stream" }); response.end("data: [DONE]\n\n"); });
    const url = await listen(server), { host } = await fixture({ turn: providerTurn, completionsUrl: url }), created = await host.create(host.config.store), reader = host.events(new AbortController().signal).getReader();
    await host.complete(host.config.store, created.id, patch(created.manifest.revision));
    assert.match((await nextType(reader, "error")).text, /DONE|JSON/);
    await host.close();
  });
});
function requestText(request: import("node:http").IncomingMessage) { return new Promise<string>((resolve) => { let text = ""; request.setEncoding("utf8"); request.on("data", (chunk) => text += chunk); request.on("end", () => resolve(text)); }); }
function delay(ms: number) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function listen(server: Server) { servers.push(server); await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve)); const address = server.address(); if (!address || typeof address === "string") throw new Error("server did not bind"); return `http://127.0.0.1:${address.port}`; }
async function nextType(reader: ReadableStreamDefaultReader<Uint8Array>, type: Event["type"]): Promise<any> { while (true) { const next = await reader.read(); if (next.done) throw new Error(`event stream ended before ${type}`); const event = JSON.parse(decoder.decode(next.value).slice(6)) as Event; if (event.type === type) return event; } }
