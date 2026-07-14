import { Runtime, parse, type Binding, type Call } from "@darkhorseprojects/circuitry";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import type { Config } from "./config.js";
import { markdownBlocks } from "./markdown-blocks.js";
import { readPacket } from "./packet.js";
import { ConflictError, Registry, Store, type CompactionDecision } from "./store.js";
import type { Context, Role, Slice, ThreadManifest, ThreadPatch } from "./thread.js";
import { loadTheme, type Theme } from "./theme.js";

export type Event =
  | { type: "update" | "done"; store: string; thread: string; revision: string }
  | { type: "deleted"; store: string; thread: string; redirect?: string }
  | { type: "reasoning" | "response" | "error"; store: string; thread: string; text: string };
type Execution = { controller: AbortController; task: Promise<void> };
type WorkingPart = { block: string; slice: Slice; role: Role; author: string; markdown: string; sources: Slice[] };
type WorkingContext = { visualRevision: string; contextRevision: string; visual: WorkingPart[]; context: WorkingPart[] };
type Usage = { prompt: number; completion: number; left: number; session: number };
type ContextView = { markdown: string; active: Set<number>; omitted: boolean };
type ActionResult = { handled: boolean; compacted: boolean };

export class BusyError extends Error { constructor() { super("A completion is already active for this thread."); } }

export class ZincHost {
  readonly runtime: Runtime;
  private program: ReturnType<typeof parse>;
  private registry!: Registry;
  private storesByPath = new Map<string, Promise<Store>>();
  private active = new Map<string, Execution>();
  private subscribers = new Map<symbol, ReadableStreamDefaultController<Uint8Array>>();
  private closed = false;

  private constructor(readonly config: Config, readonly theme: Theme, private stateDirectory: string, turn: string) {
    this.program = parse(turn);
    this.runtime = new Runtime({ parallel: config.parallel, env: process.env, authorize: (call) => authorize(config, call) });
  }

  static async open(config: Config, state: string) {
    const host = new ZincHost(config, await loadTheme(config.theme), state, await readFile(config.turn, "utf8"));
    host.registry = await Registry.open(join(state, "stores.jsonl"), config.store);
    return host;
  }

  stores() { return this.registry.list(); }
  async addStore(path: string, name?: string) { this.open(); await this.registry.add(path, name); return this.stores(); }
  async removeStore(path: string) { this.open(); const target = resolve(path); await this.registry.remove(target); const opened = this.storesByPath.get(target); if (opened) { await (await opened).close(); this.storesByPath.delete(target); } return this.stores(); }
  async threads(store: string) { return (await this.store(store)).list(); }
  async create(store: string) { this.open(); return (await this.store(store)).create(); }
  async manifest(store: string, thread: string) { return (await this.store(store)).manifest(thread); }
  async blocks(store: string, thread: string, revision: string, ids: string[]) { return (await this.store(store)).readBlocks(thread, revision, ids); }
  async delete(store: string, thread: string) { this.open(); return (await this.store(store)).delete(thread); }
  async release(store: string, thread: string) { this.open(); return (await this.store(store)).release(thread); }

  packet(store: string, packet: string, from?: number, to?: number) { return readPacket(resolve(store), join(this.stateDirectory, "packets"), packet, from, to); }

  async source(store: string, thread: string, revision: string, block: string, source: number) {
    this.open(); const path = resolve(store), result = await (await this.store(path)).applySource(thread, revision, block, source, this.config.author);
    if (result.collapsedTo) this.publish({ type: "deleted", store: path, thread, redirect: result.collapsedTo });
    else this.publish({ type: "update", store: path, thread, revision: result.manifest.revision });
    return result;
  }

  async fork(store: string, thread: string, revision: string, block: string) {
    this.open(); const path = resolve(store), created = await (await this.store(path)).fork(thread, revision, block);
    this.publish({ type: "update", store: path, thread, revision });
    this.publish({ type: "update", store: path, thread: created.id, revision: created.manifest.revision });
    return created;
  }

  async commit(store: string, thread: string, patch: ThreadPatch) {
    this.open(); const path = resolve(store), result = await (await this.store(path)).commit(thread, patch, this.config.author);
    if (result.collapsedTo) this.publish({ type: "deleted", store: path, thread, redirect: result.collapsedTo });
    else this.publish({ type: "update", store: path, thread, revision: result.manifest.revision });
    return result;
  }

  async complete(store: string, thread: string, patch: ThreadPatch) {
    this.open(); const path = resolve(store), key = `${path}\0${thread}`;
    if (this.active.has(key)) throw new BusyError();
    const controller = new AbortController(); let release!: () => void;
    const reserved = new Promise<void>((done) => { release = done; }); this.active.set(key, { controller, task: reserved });
    try {
      const opened = await this.store(path), committed = await opened.commit(thread, patch, this.config.author);
      if (committed.collapsedTo) throw new Error("A completion patch cannot collapse its thread");
      const working = await this.working(opened, thread);
      this.publish({ type: "update", store: path, thread, revision: committed.manifest.revision });
      const task = this.execute(path, thread, working, controller.signal)
        .catch(async (error) => {
          if (controller.signal.aborted) {
            const latest = await this.manifest(path, thread).catch(() => null);
            if (latest) this.publish({ type: "done", store: path, thread, revision: latest.revision });
            return;
          }
          const latest = await this.appendError(path, thread, message(error)).catch(() => null);
          if (latest) this.publish({ type: "update", store: path, thread, revision: latest.revision });
          this.publish({ type: "error", store: path, thread, text: message(error) });
        })
        .finally(() => { this.active.delete(key); release(); });
      this.active.set(key, { controller, task });
      return committed.manifest;
    } catch (error) { this.active.delete(key); release(); throw error; }
  }

  cancel(store: string, thread: string) { const running = this.active.get(`${resolve(store)}\0${thread}`); if (!running) return false; running.controller.abort(new Error("Completion cancelled")); return true; }

  events(signal: AbortSignal) {
    return new ReadableStream<Uint8Array>({ start: (controller) => {
      const key = Symbol(), close = () => { this.subscribers.delete(key); try { controller.close(); } catch {} };
      this.subscribers.set(key, controller); signal.addEventListener("abort", close, { once: true });
    }});
  }

  async close() {
    if (this.closed) return; this.closed = true;
    for (const running of this.active.values()) running.controller.abort(new Error("Zinc host closed"));
    await Promise.allSettled([...this.active.values()].map(({ task }) => task));
    for (const subscriber of this.subscribers.values()) try { subscriber.close(); } catch {}
    this.subscribers.clear(); await Promise.allSettled([...this.storesByPath.values()].map(async (store) => (await store).close())); this.storesByPath.clear();
  }

  private async execute(storePath: string, thread: string, initial: WorkingContext, signal: AbortSignal) {
    const store = await this.store(storePath), seen = new Set<string>();
    let working = initial, usage: Usage = { prompt: 0, completion: 0, left: this.config.contextTokens, session: 0 };
    let pendingCompact = threshold((await store.state(thread)).promptTokens, this.config), responseWaiting = false;
    const append = async (role: "agent" | "system", values: Uint8Array[]) => {
      const result = await store.appendMany(thread, role, values); working = await this.working(store, thread);
      this.publish({ type: "update", store: storePath, thread, revision: result.manifest.revision }); return result.manifest;
    };

    while (true) {
      signal.throwIfAborted();
      const view = contextView(working.context, this.config.rawContextBytes); pendingCompact ||= view.omitted;
      const definitions = await definitionCatalog(join(this.stateDirectory, "definitions"), pendingCompact);
      const run = this.runtime.start(this.program, inputs(this.config, this.stateDirectory, working, view, usage, definitions, pendingCompact), {
        cwd: dirname(this.config.turn), seen, signal,
        output: (_entry, binding) => { if (!pendingCompact && (binding.name === "reasoning" || binding.name === "response") && typeof binding.value === "string" && binding.value) this.publish({ type: binding.name, store: storePath, thread, text: binding.value }); },
      });
      let advanced = false; while (await run.advance()) advanced = true;
      if (!advanced) throw new Error("Configured turn produced no output");
      const root = run.output().bindings; if (!root.length) throw new Error("Configured turn produced no root output");
      usage = updateUsage(usage, root, this.config.contextTokens);
      const actions = strings(root, "circuitry").map((value) => value.trim()).filter(Boolean), response = strings(root, "response").join("").trim();
      let actionFailed = false, compacted = false;

      if (!pendingCompact) {
        const reasoning = strings(root, "reasoning").join("").trim(); if (reasoning) await append("agent", [textPacket("reasoning", reasoning)]);
        if (response) await append("agent", responsePackets(response));
      }

      for (const document of actions) {
        if (!pendingCompact) await append("system", [textPacket("kdl", document)]);
        const calls: Array<{ source: string; args: string[]; documents: unknown[] }> = [];
        try {
          const nested = this.runtime.start(parse(document), inputs(this.config, this.stateDirectory, working, contextView(working.context, this.config.rawContextBytes), usage, definitions, pendingCompact), {
            cwd: dirname(this.config.turn), signal,
            call: async (call, documents) => { if (call.source !== this.config.completionsUrl) calls.push({ source: call.source ?? "", args: call.args, documents }); },
          });
          while (await nested.advance()) {}
          const result = nested.output().value; usage = updateUsage(usage, nested.output().bindings, this.config.contextTokens);
          const handled = await this.applyAction(store, thread, working, result, append, pendingCompact); compacted ||= handled.compacted;
          if (handled.compacted) { working = await this.working(store, thread); usage = { prompt: 0, completion: 0, left: this.config.contextTokens, session: usage.session }; }
          else if (!handled.handled) {
            const processes = calls.filter(processCall);
            if (processes.length) await append("system", processes.map((call) => structuredPacket({ zinc: "shell", command: [call.source, ...call.args].join(" "), output: call.documents.map(printValue).join("") })));
            else { const text = JSON.stringify(result, null, 2); await append("system", [textPacket("json", text)]); }
          }
        } catch (error) {
          signal.throwIfAborted(); actionFailed = true; if (pendingCompact) throw error; await append("system", [textPacket("error", message(error))]);
        }
      }

      if (pendingCompact) {
        if (!compacted) throw new Error("Compact event was not resolved"); pendingCompact = false;
        if (responseWaiting) { const state = await store.state(thread); this.publish({ type: "done", store: storePath, thread, revision: state.visualRevision }); return; }
        continue;
      }

      const state = await store.state(thread); if (usage.prompt > 0) await store.recordPromptTokens(thread, state.contextRevision, usage.prompt);
      const terminal = !actionFailed && actions.length === 0 && Boolean(response);
      pendingCompact = threshold(usage.prompt, this.config) || contextView(working.context, this.config.rawContextBytes).omitted;
      if (terminal && pendingCompact) { responseWaiting = true; continue; }
      if (terminal) { this.publish({ type: "done", store: storePath, thread, revision: state.visualRevision }); return; }
    }
  }

  private async applyAction(store: Store, thread: string, working: WorkingContext, result: unknown, append: (role: "agent" | "system", values: Uint8Array[]) => Promise<ThreadManifest>, pendingCompact: boolean): Promise<ActionResult> {
    if (!record(result)) return { handled: false, compacted: false };
    const compact = compactionResult(result, working.context.map((part) => part.slice));
    if (compact) { if (!pendingCompact) throw new Error("Compaction requires a compact event"); await store.compact(thread, working.contextRevision, compact); return { handled: true, compacted: true }; }
    const recall = recallResult(result); if (recall) { await append("system", [structuredPacket({ zinc: "recall", ...recall })]); return { handled: true, compacted: false }; }
    const definition = definitionResult(result);
    if (definition) {
      const program = parse(definition.document); if (!program.sections.Description || !program.sections.Use) throw new Error("Circuitry definitions require Description and Use sections");
      const directory = join(this.stateDirectory, "definitions"); await mkdir(directory, { recursive: true }); const path = join(directory, `${definition.name}.md`), temporary = `${path}.tmp`;
      await writeFile(temporary, definition.document); await rename(temporary, path); await append("system", [structuredPacket({ zinc: "definition", ...definition })]); return { handled: true, compacted: false };
    }
    return { handled: false, compacted: false };
  }

  private async working(store: Store, thread: string): Promise<WorkingContext> {
    const visual = await store.read(thread), context = await store.readContext(thread);
    return { visualRevision: visual.revision, contextRevision: context.revision, visual: workingParts(visual), context: workingParts(context) };
  }

  private async appendError(store: string, thread: string, text: string) { const result = await (await this.store(store)).appendMany(thread, "system", [textPacket("error", text)]); return result.manifest; }
  private store(path: string) { const absolute = resolve(path); let store = this.storesByPath.get(absolute); if (!store) { store = Store.open({ path: absolute, packets: join(this.stateDirectory, "packets"), overflowBytes: this.config.packetOverflowBytes }); this.storesByPath.set(absolute, store); } return store; }
  private publish(event: Event) { const bytes = new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`); for (const subscriber of this.subscribers.values()) try { subscriber.enqueue(bytes); } catch {} }
  private open() { if (this.closed) throw new Error("Zinc host is closed"); }
}

type Format = "markdown" | "reasoning" | "error" | "json" | "kdl" | "tsx";
function structuredPacket(value: Record<string, unknown>) { return new TextEncoder().encode(`${JSON.stringify(value)}\n`); }
function textPacket(format: Format, text: string) { return structuredPacket({ zinc: "text", format, text }); }
function responsePackets(markdown: string) { const blocks = markdownBlocks(markdown); return (blocks.length ? blocks.map((block) => block.raw.trimEnd()).filter(Boolean) : [markdown]).map((text) => textPacket("markdown", text)); }
function workingParts(context: Context): WorkingPart[] { return context.parts.map((part) => ({ block: part.id, slice: part.slice, role: part.role, author: part.author, markdown: packetMarkdown(part.bytes, part.slice), sources: part.sources })); }
function inputs(config: Config, state: string, working: WorkingContext, view: ContextView, usage: Usage, definitions: string, compact: boolean) {
  return {
    thread: cleanMarkdown(working.visual), context: view.markdown, packets: packetCatalog(working, view.active), "compact-candidates": working.context.map((part, index) => packetRecord("context", part, view.active.has(index))), event: compact ? "compact" : "respond",
    shell: config.shell, "completions-url": config.completionsUrl, cwd: state, allowlist: config.allowlist.join(", ") || "(none)", definitions: join(state, "definitions"), "available-definitions": definitions || "No definitions are available.",
    "token-limit": config.contextTokens, "compact-at": config.compactAt, "prompt-tokens": usage.prompt, "completion-tokens": usage.completion, "tokens-left": usage.left, "session-tokens": usage.session,
  };
}
function packetCatalog(working: WorkingContext, active: Set<number>) { return [...working.visual.map((part) => packetRecord("thread", part, true)), ...working.context.map((part, index) => packetRecord("context", part, active.has(index)))]; }
function packetRecord(scope: string, part: WorkingPart, active: boolean) { return { scope, block: part.block, ...part.slice, role: part.role, author: part.author, sources: part.sources, active, content: part.markdown }; }
function contextView(parts: WorkingPart[], limit: number): ContextView {
  const blocks = parts.map(cleanPart), selected: string[] = [], active = new Set<number>(); let size = 0, omitted = false;
  for (let index = blocks.length - 1; index >= 0; index--) { const sizeOf = new TextEncoder().encode(blocks[index]).byteLength + (selected.length ? 2 : 0); if (size + sizeOf > limit) { omitted = true; if (!selected.length) { selected.unshift(blocks[index]); active.add(index); } break; } selected.unshift(blocks[index]); active.add(index); size += sizeOf; }
  return { markdown: selected.join("\n\n"), active, omitted };
}
function cleanMarkdown(parts: WorkingPart[]) { return parts.map(cleanPart).join("\n\n"); }
function cleanPart(part: WorkingPart) { return `### ${part.role}\n\n${part.markdown}`; }
function packetMarkdown(bytes: Uint8Array, slice: Slice) {
  const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); if (!record(value)) throw new Error("Context packet has no Markdown projection");
  if (value.zinc === "text" && typeof value.text === "string") {
    if (value.format === "markdown" && (slice.from !== undefined || slice.to !== undefined)) return markdownBlocks(value.text).slice(slice.from ?? 0, slice.to).map((block) => block.raw).join("");
    return value.format === "reasoning" ? `\`\`\`reasoning\n${value.text}\n\`\`\`` : value.format === "error" ? `\`\`\`error\n${value.text}\n\`\`\`` : value.format === "tsx" ? `\`\`\`tsx\n${value.text}\n\`\`\`` : value.text;
  }
  if (value.zinc === "recall" && typeof value.content === "string") return value.content;
  if (value.zinc === "shell" && typeof value.command === "string" && typeof value.output === "string") return `\`\`\`shell\n$ ${value.command}\n${value.output}\n\`\`\``;
  if (value.zinc === "definition" && typeof value.document === "string") return `\`\`\`kdl\n${value.document}\n\`\`\``;
  throw new Error("Context packet has no Markdown projection");
}
function strings(bindings: Binding[], name: string) { return bindings.flatMap((binding) => binding.name === name && typeof binding.value === "string" ? [binding.value] : []); }
function number(bindings: Binding[], name: string) { for (let index = bindings.length - 1; index >= 0; index--) if (bindings[index].name === name) { const value = bindings[index].value; return typeof value === "number" && Number.isFinite(value) ? value : null; } return null; }
function updateUsage(current: Usage, bindings: Binding[], limit: number): Usage { const prompt = number(bindings, "prompt-tokens"), completion = number(bindings, "completion-tokens"), total = number(bindings, "used-tokens"); if (prompt === null && completion === null && total === null) return current; const used = total ?? (prompt ?? 0) + (completion ?? 0); return { prompt: prompt ?? 0, completion: completion ?? 0, left: Math.max(0, limit - used), session: current.session + used }; }
function threshold(promptTokens: number, config: Config) { return promptTokens > 0 && promptTokens * 100 >= config.contextTokens * config.compactAt; }
async function definitionCatalog(directory: string, includeCompact: boolean) { const files = (await readdir(directory).catch(() => [])).filter((file) => /\.(?:md|kdl)$/i.test(file) && (includeCompact || !/^compact\.(?:md|kdl)$/i.test(file))).sort(), entries: string[] = []; for (const file of files) try { const program = parse(await readFile(join(directory, file), "utf8")); if (program.sections.Description && program.sections.Use) entries.push(`### ${file.replace(/\.(?:md|kdl)$/i, "")}\n${program.sections.Description}\n\n${program.sections.Use}`); } catch {} return entries.join("\n\n"); }
function compactionResult(value: Record<string, unknown>, candidates: Slice[]): CompactionDecision[] | null { const raw = value.compaction, values = Array.isArray(raw) ? raw : record(raw) && Array.isArray(raw.decisions) ? raw.decisions : null; if (!values) return null; return values.map((item): CompactionDecision => { if (!record(item) || !["keep", "summarize", "drop"].includes(String(item.action)) || typeof item.rank !== "number") throw new Error("Invalid compaction result"); if (!Array.isArray(item.indexes) || !item.indexes.length || !item.indexes.every((index: unknown) => Number.isInteger(index) && Number(index) >= 0 && Number(index) < candidates.length)) throw new Error("Compaction decision has invalid candidate indexes"); const sources = item.indexes.map((index: number) => candidates[index]); if (item.action === "summarize") { if (typeof item.content !== "string" || !item.content.trim()) throw new Error("Compaction summary requires Markdown content"); return { action: "summarize", sources, rank: item.rank, bytes: textPacket("markdown", item.content) }; } return { action: item.action as "keep" | "drop", sources, rank: item.rank }; }); }
function recallResult(value: Record<string, unknown>) { return typeof value.packet === "string" && typeof value.content === "string" ? { packet: value.packet, content: value.content, ...(Number.isInteger(value.from) ? { from: Number(value.from) } : {}), ...(Number.isInteger(value.to) ? { to: Number(value.to) } : {}) } : null; }
function definitionResult(value: Record<string, unknown>) { if (!record(value.definition) || typeof value.definition.name !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(value.definition.name) || typeof value.definition.document !== "string") return null; return { name: value.definition.name, document: value.definition.document }; }
function processCall(call: { source: string }) { return Boolean(call.source) && !/^https?:/i.test(call.source) && !/\.(?:md|kdl)$/i.test(call.source); }
function printValue(value: unknown) { return typeof value === "string" ? value : JSON.stringify(value, null, 2); }
function record(value: unknown): value is Record<string, any> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function message(error: unknown) { return error instanceof Error ? error.message : String(error); }
function authorize(config: Config, call: Call) { if (!config.allowlist.length || !call.source || (call.source.split(/[\\/]/).pop() ?? call.source) !== (config.shell.split(/[\\/]/).pop() ?? config.shell)) return; const command = call.args.find((value) => !value.startsWith("-"))?.trim().split(/\s+/)[0]; if (command && !config.allowlist.includes(command)) throw new Error(`command '${command}' is not in the allowlist`); }
export { ConflictError };
