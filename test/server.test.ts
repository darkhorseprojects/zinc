import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, it } from "node:test";
import { ZincHost } from "../src/host.js";
import { compileTsxPreview, createRequestHandler } from "../src/server.js";
import type { Config } from "../src/config.js";

const roots: string[] = [], encoder = new TextEncoder();
afterEach(() => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));
async function fixture() { const root = await mkdtemp(join(tmpdir(), "zinc-server-")); roots.push(root); const turn = join(root, "turn.md"), client = join(root, "client"), fonts = join(client, "fonts"); await mkdir(fonts, { recursive: true }); await writeFile(join(client, "index.html"), "ok"); await writeFile(join(client, "app-12345678.js"), "ok"); await writeFile(join(fonts, "prose.woff2"), "ok"); await writeFile(turn, `out {}`); const config: Config = { store: join(root, "zinc.db"), turn, theme: join(process.cwd(), "defaults", "theme.kdl"), url: "localhost", port: 5173, author: "anonymous", completionsUrl: "http://localhost", parallel: 1, rawContextBytes: 10, contextTokens: 32768, compactAt: 80, packetOverflowBytes: 100, shell: "sh", allowlist: [] }; const host = await ZincHost.open(config, root); return { host, request: createRequestHandler(host, client) }; }
const packet = (text: string) => Buffer.from(encoder.encode(`${JSON.stringify({ zinc: "text", format: "markdown", text })}\n`)).toString("base64");
const post = (value: unknown) => ({ method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(value) });

describe("server v8", () => {
  it("creates manifests, commits stable blocks, and batches payload reads", async () => {
    const { host, request } = await fixture(), createdResponse = await request(new Request("http://z/api/threads", post({ store: host.config.store }))), created: any = await createdResponse.json();
    assert.match(created.id, /^thr_/);
    const savedResponse = await request(new Request("http://z/api/thread", post({ store: host.config.store, thread: created.id, patch: { revision: created.manifest.revision, order: ["a"], writes: [{ id: "a", origins: [], bytes: packet("hello") }] } }))), saved: any = await savedResponse.json();
    assert.equal(saved.manifest.blocks[0].id, "a");
    assert.equal(saved.manifest.blocks[0].role, "user");
    const loaded = await request(new Request("http://z/api/blocks/read", post({ store: host.config.store, thread: created.id, revision: saved.manifest.revision, ids: ["a"] })));
    assert.equal(JSON.parse(Buffer.from((await loaded.json() as any).blocks[0].bytes, "base64").toString()).text, "hello");
    await host.close();
  });
  it("validates patch bytes and stable block source/fork requests", async () => {
    const { host, request } = await fixture(), created = await host.create(host.config.store);
    const bad = await request(new Request("http://z/api/thread", post({ store: host.config.store, thread: created.id, patch: { revision: created.manifest.revision, order: ["a"], writes: [{ id: "a", origins: [], bytes: "***" }] } })));
    assert.equal(bad.status, 400);
    await host.close();
  });
  it("serves the configured theme and explicit cache policies", async () => {
    const { host, request } = await fixture(), theme = await request(new Request("http://z/theme.css"));
    assert.equal(theme.headers.get("cache-control"), "no-cache");
    assert.match(await theme.text(), /--z-background:#090d12/);
    assert.equal((await request(new Request("http://z/api/stores"))).headers.get("cache-control"), "no-store");
    assert.equal((await request(new Request("http://z/app-12345678.js"))).headers.get("cache-control"), "public, max-age=31536000, immutable");
    await host.close();
  });
  it("guards previews and static traversal", async () => {
    const { host, request } = await fixture();
    assert.equal(compileTsxPreview(`export default function A(){return <div/>}`).ok, true);
    assert.equal(compileTsxPreview(`import fs from "node:fs"; export default function A(){}`).ok, false);
    assert.equal((await request(new Request("http://z/%2e%2e%2fsecret"))).status, 400);
    await host.close();
  });
});
