import { transformSync } from "@babel/core";
import { parse } from "@babel/parser";
import { createRequire } from "node:module";
import { readFile, stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, dirname, extname, join, normalize } from "node:path";
import { Readable } from "node:stream";
import { finished } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { defaultConfigPath, loadConfig } from "./config.js";
import { BusyError, ConflictError, ZincHost } from "./host.js";
import type { ThreadPatch } from "./thread.js";
import { themeCss } from "./theme.js";

const require = createRequire(import.meta.url), transformModules = require("@babel/plugin-transform-modules-commonjs"), typescript = require("@babel/preset-typescript"), solid = require("babel-preset-solid");
const mime: Record<string, string> = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2" };
const previewImports = new Set(["solid-js", "solid-js/web", "@kobalte/core", "animejs"]);
type ObjectValue = Record<string, unknown>;
export type CompileResult = { ok: true; code: string } | { ok: false; error: string };

export function createRequestHandler(host: ZincHost, clientRoot: string) {
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url), route = url.pathname;
    try {
      if (route === "/theme.css") {
        if (request.method !== "GET") return method();
        return new Response(themeCss(host.theme), { headers: { "content-type": "text/css; charset=utf-8", "cache-control": "no-cache" } });
      }
      if (route === "/api/bootstrap") {
        if (request.method !== "GET") return method();
        const stores = host.stores(), store = url.searchParams.get("store") ?? stores[0]?.path ?? null, threads = store ? await host.threads(store) : [], selected = url.searchParams.get("thread"), thread = selected && threads.some((item) => item.id === selected) ? selected : threads[0]?.id ?? null;
        const manifest = store && thread ? await host.manifest(store, thread).catch(() => null) : null;
        return json({ stores, store, threads, thread, manifest, author: host.config.author, rawContextBytes: host.config.rawContextBytes });
      }
      if (route === "/api/stores") {
        if (request.method === "GET") return json({ stores: host.stores() });
        if (request.method !== "POST") return method();
        const value = await body(request); if (!object(value) || typeof value.path !== "string") return bad("Missing store path");
        return json({ stores: await host.addStore(value.path, typeof value.name === "string" ? value.name : undefined) });
      }
      if (route === "/api/threads") {
        if (request.method === "GET") { const store = url.searchParams.get("store"); return store ? json({ threads: await host.threads(store) }) : bad("Missing store"); }
        if (request.method !== "POST") return method();
        const value = await body(request); if (!object(value) || typeof value.store !== "string") return bad("Missing store");
        return json(await host.create(value.store));
      }
      if (route === "/api/thread") {
        if (request.method === "GET" || request.method === "DELETE") {
          const store = url.searchParams.get("store"), thread = url.searchParams.get("thread"); if (!store || !thread) return bad("Missing store or thread");
          return request.method === "GET" ? json(await host.manifest(store, thread)) : json({ deleted: await host.delete(store, thread) });
        }
        if (request.method !== "POST") return method();
        const value = await body(request), patch = object(value) ? decodePatch(value.patch) : null;
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string" || !patch) return bad("Invalid thread patch");
        return json(await host.commit(value.store, value.thread, patch));
      }
      if (route === "/api/thread/release") {
        if (request.method !== "POST") return method(); const value = await body(request);
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string") return bad("Invalid thread release");
        return json(await host.release(value.store, value.thread));
      }
      if (route === "/api/blocks/read") {
        if (request.method !== "POST") return method(); const value = await body(request);
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string" || typeof value.revision !== "string" || !Array.isArray(value.ids) || !value.ids.every((id) => typeof id === "string")) return bad("Invalid block read");
        return json({ revision: value.revision, blocks: (await host.blocks(value.store, value.thread, value.revision, value.ids)).map(({ bytes, ...block }) => ({ ...block, bytes: Buffer.from(bytes).toString("base64") })) });
      }
      if (route === "/api/source") {
        if (request.method === "GET") {
          const store = url.searchParams.get("store"), packet = url.searchParams.get("packet"), rawFrom = url.searchParams.get("from"), rawTo = url.searchParams.get("to"); if (!store || !packet) return bad("Missing store or packet");
          const from = rawFrom === null ? undefined : integer(rawFrom), to = rawTo === null ? undefined : integer(rawTo); if (from === null || to === null || to !== undefined && to <= (from ?? 0)) return bad("Invalid source range");
          return new Response(Buffer.from(await host.packet(store, packet, from, to)), { headers: { "content-type": "application/octet-stream", "cache-control": "no-store" } });
        }
        if (request.method !== "POST") return method(); const value = await body(request);
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string" || typeof value.revision !== "string" || typeof value.block !== "string" || !Number.isInteger(value.source) || Number(value.source) < 0) return bad("Invalid source application");
        return json(await host.source(value.store, value.thread, value.revision, value.block, Number(value.source)));
      }
      if (route === "/api/fork") {
        if (request.method !== "POST") return method(); const value = await body(request);
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string" || typeof value.revision !== "string" || typeof value.block !== "string") return bad("Invalid fork");
        return json(await host.fork(value.store, value.thread, value.revision, value.block));
      }
      if (route === "/api/completions") {
        if (request.method !== "POST" && request.method !== "DELETE") return method(); const value = await body(request);
        if (!object(value) || typeof value.store !== "string" || typeof value.thread !== "string") return bad("Invalid completion");
        if (request.method === "DELETE") return json({ cancelled: host.cancel(value.store, value.thread) });
        const patch = decodePatch(value.patch); if (!patch) return bad("Invalid completion patch");
        return json({ started: true, ...await host.complete(value.store, value.thread, patch) }, 202);
      }
      if (route === "/api/events") return request.method === "GET" ? new Response(host.events(request.signal), { headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store" } }) : method();
      if (route === "/api/tsx/compile") { if (request.method !== "POST") return method(); const value = await body(request); return object(value) && typeof value.source === "string" ? json(compileTsxPreview(value.source)) : bad("Missing TSX source"); }
      if (route.startsWith("/api/")) return json({ error: "Not found" }, 404);
      return await staticFile(clientRoot, route);
    } catch (error) {
      if (error instanceof ConflictError || error instanceof BusyError) return json({ error: error.message, ...(error instanceof ConflictError ? { current: error.current } : {}) }, 409);
      if (error instanceof SyntaxError || error instanceof RequestError) return bad(error.message);
      return json({ error: error instanceof Error ? error.message : String(error) }, 500);
    }
  };
}

function decodePatch(value: unknown): ThreadPatch | null {
  if (!object(value) || typeof value.revision !== "string" || !Array.isArray(value.order) || !value.order.every((id) => typeof id === "string") || !Array.isArray(value.writes)) return null;
  if (value.identifier !== undefined && typeof value.identifier !== "string") return null;
  const writes: ThreadPatch["writes"] = [];
  for (const write of value.writes) {
    if (!object(write) || typeof write.id !== "string" || !Array.isArray(write.origins) || !write.origins.every((id) => typeof id === "string")) return null;
    const content = base64(write.bytes); if (!content) return null; writes.push({ id: write.id, origins: write.origins, bytes: content });
  }
  return { revision: value.revision, ...(typeof value.identifier === "string" ? { identifier: value.identifier } : {}), order: value.order, writes };
}

export function compileTsxPreview(source: string): CompileResult {
  try {
    guard(source);
    const result = transformSync(source, { babelrc: false, configFile: false, filename: "zinc-preview.tsx", presets: [[solid, { generate: "dom" }], [typescript, { allExtensions: true, isTSX: true }]], plugins: [transformModules], sourceMaps: false });
    return result?.code ? { ok: true, code: result.code } : { ok: false, error: "TSX compiler produced no code" };
  } catch (error) { return { ok: false, error: error instanceof Error ? error.message : String(error) }; }
}
function guard(source: string) { const tree = parse(source, { sourceType: "module", plugins: ["jsx", "typescript"] }); let exported = false; walk(tree, (node) => { if (node.type === "ExportDefaultDeclaration") exported = true; if (node.type === "ImportDeclaration" && !previewImports.has(String((node.source as { value?: unknown }).value ?? ""))) throw new Error("Unsupported TSX preview import"); if (node.type === "ImportExpression" || node.type === "Import") throw new Error("Dynamic import is not allowed"); if (node.type === "CallExpression" && (node.callee as { name?: string }).name === "require") throw new Error("require() is not allowed"); }); if (!exported) throw new Error("TSX preview must export a default Solid component"); }

export async function startServer(path = defaultConfigPath()) {
  const config = await loadConfig(path), host = await ZincHost.open(config, dirname(path)), root = fileURLToPath(new URL("./client/", import.meta.url)), handler = createRequestHandler(host, root);
  const server = createServer((incoming, outgoing) => { void handler(nodeRequest(incoming, config.url, config.port)).then((response) => send(outgoing, response)).catch((error) => { if (disconnected(error)) return; if (!outgoing.headersSent) { outgoing.writeHead(500, { "content-type": "application/json" }); outgoing.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) })); } else outgoing.destroy(error instanceof Error ? error : new Error(String(error))); }); });
  await new Promise<void>((done, fail) => { server.once("error", fail); server.listen(config.port, config.url, done); });
  const close = async () => { await new Promise<void>((done) => server.close(() => done())); await host.close(); };
  console.log(`zinc web listening on ${formatHost(config.url, config.port)}`); return { host, close };
}

async function staticFile(root: string, pathname: string) { let decoded: string; try { decoded = decodeURIComponent(pathname); } catch { throw new RequestError("Invalid path"); } if (decoded.includes("\\") || decoded.includes("\0") || decoded.split("/").includes("..")) throw new RequestError("Invalid path"); const safe = normalize(decoded).replace(/^[/]+/, ""); if (!safe || safe === ".") return file(join(root, "index.html")); if (safe === ".." || safe.startsWith(`..${join("a", "b").slice(1, 2)}`) || /^[A-Za-z]:/.test(safe)) throw new RequestError("Invalid path"); const requested = join(root, safe); if (await isFile(requested)) return file(requested); if (extname(safe)) return json({ error: "Not found" }, 404); return file(join(root, "index.html")); }
async function file(path: string) { const extension = extname(path), name = basename(path), cache = name === "index.html" ? "no-cache" : extension === ".woff2" || /-[A-Za-z0-9_-]{8,}\.[^.]+$/.test(name) ? "public, max-age=31536000, immutable" : "no-cache"; return new Response(await readFile(path), { headers: { "content-type": mime[extension] ?? "application/octet-stream", "cache-control": cache } }); }
async function isFile(path: string) { try { return (await stat(path)).isFile(); } catch { return false; } }
function base64(value: unknown) { if (typeof value !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return null; return new Uint8Array(Buffer.from(value, "base64")); }
function json(value: unknown, status = 200) { return Response.json(value, { status, headers: { "cache-control": "no-store" } }); }
function bad(error: string) { return json({ error }, 400); }
function method() { return json({ error: "Method not allowed" }, 405); }
async function body(request: Request) { try { return await request.json(); } catch { throw new RequestError("Invalid JSON"); } }
function object(value: unknown): value is ObjectValue { return typeof value === "object" && value !== null && !Array.isArray(value); }
function integer(value: string) { const number = Number(value); return Number.isInteger(number) && number >= 0 ? number : null; }
function walk(value: unknown, visit: (node: ObjectValue) => void) { if (!value || typeof value !== "object") return; if (Array.isArray(value)) return void value.forEach((item) => walk(item, visit)); const node = value as ObjectValue; if (typeof node.type === "string") visit(node); for (const [key, child] of Object.entries(node)) if (!["loc", "start", "end", "extra"].includes(key)) walk(child, visit); }
function formatHost(host: string, port: number) { return `${host.includes(":") ? `[${host}]` : host}:${port}`; }
class RequestError extends Error {}
function nodeRequest(request: IncomingMessage, host: string, port: number) { const method = request.method ?? "GET", headers = new Headers(); for (const [key, value] of Object.entries(request.headers)) if (Array.isArray(value)) value.forEach((item) => headers.append(key, item)); else if (value !== undefined) headers.set(key, value); const stream = method === "GET" || method === "HEAD" ? undefined : new ReadableStream<Uint8Array>({ async start(controller) { for await (const chunk of request) controller.enqueue(typeof chunk === "string" ? new TextEncoder().encode(chunk) : chunk); controller.close(); } }); return new Request(new URL(request.url ?? "/", `http://${request.headers.host ?? formatHost(host, port)}`), { method, headers, body: stream, ...(stream ? { duplex: "half" } : {}) }); }
async function send(output: ServerResponse, response: Response) { output.writeHead(response.status, Object.fromEntries(response.headers)); if (!response.body) return void output.end(); Readable.from(response.body as unknown as AsyncIterable<Uint8Array>).pipe(output); await finished(output); }
function disconnected(error: unknown) { return error instanceof Error && "code" in error && (error.code === "ERR_STREAM_PREMATURE_CLOSE" || error.code === "ECONNRESET"); }
