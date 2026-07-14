import { connect } from "@tursodatabase/database";
import { spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseConfig } from "../src/config.js";
import { Store } from "../src/store.js";

const roots: string[] = [], project = process.cwd();
afterEach(() => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));
function run(args: string[], env: NodeJS.ProcessEnv = {}, cwd = project) { return new Promise<{ code: number; out: string; error: string }>((done, fail) => { const child = spawn("edge", [join(project, "bin", "zn.js"), ...args], { cwd, env: { ...process.env, ...env } }); let out = "", error = ""; child.stdout.on("data", (value) => out += value); child.stderr.on("data", (value) => error += value); child.once("error", fail); child.once("exit", (code) => done({ code: code ?? 1, out, error })); }); }

describe("CLI lifecycle", () => {
  it("validates compaction as an integer percentage", () => {
    expect(parseConfig('store "zinc.db"\nturn "turn.md"\ntheme "theme.kdl"\ncompact-at 80', "/tmp").compactAt).toBe(80);
    expect(() => parseConfig('store "zinc.db"\nturn "turn.md"\ntheme "theme.kdl"\ncompact-at 101', "/tmp")).toThrow(/percentage/);
  });

  it("initializes canonical v8 state through the built core", async () => {
    const root = await mkdtemp(join(tmpdir(), "zinc-life-")); roots.push(root); const config = join(root, "config.kdl");
    const result = await run(["init", "--config", config]); expect(result).toMatchObject({ code: 0 });
    expect(await readFile(config, "utf8")).not.toContain("zinc-dir");
    const status = await run(["status", "--config", config]); expect(status.out).toContain("status: stopped");
  });

  it("cleans the selected OS configuration without deleting unrelated or external files", async () => {
    const root = await mkdtemp(join(tmpdir(), "zinc-clean-config-")), external = await mkdtemp(join(tmpdir(), "zinc-external-")); roots.push(root, external);
    const config = join(root, "config.kdl"), externalStore = join(external, "external.db"), unrelated = join(root, "keep.txt");
    await run(["init", "--config", config]);
    await writeFile(unrelated, "keep");
    await writeFile(config, `store "${externalStore}"\nturn "turn.md"\ntheme "theme.kdl"\n`);
    const store = await Store.open({ path: externalStore, packets: join(external, "packets"), overflowBytes: 64 }); await store.close();
    const result = await run(["clean", "--user"], { ZINC_CONFIG: config });
    expect(result).toMatchObject({ code: 0 });
    await expect(access(config)).rejects.toThrow();
    await expect(access(externalStore)).resolves.toBeUndefined();
    expect(await readFile(unrelated, "utf8")).toBe("keep");
  });

  it("cleans local state with --here or no target", async () => {
    for (const target of [[], ["--here"]]) {
      const root = await mkdtemp(join(tmpdir(), "zinc-clean-here-")); roots.push(root);
      expect(await run(["here"], {}, root)).toMatchObject({ code: 0 });
      await writeFile(join(root, "keep.txt"), "keep");
      const result = await run(["clean", ...target], {}, root);
      expect(result).toMatchObject({ code: 0 });
      await expect(access(join(root, ".zinc"))).rejects.toThrow();
      expect(await readFile(join(root, "keep.txt"), "utf8")).toBe("keep");
    }
  });

  it("rejects multiple clean targets", async () => {
    const result = await run(["clean", "--here", "--user"]);
    expect(result.code).toBe(1);
    expect(result.error).toContain("exactly one target");
  });

  it("cleans explicit thread and packet targets", async () => {
    const root = await mkdtemp(join(tmpdir(), "zinc-clean-target-")); roots.push(root);
    const config = join(root, "config.kdl"); await run(["init", "--config", config]);
    const store = await Store.open({ path: join(root, "zinc.db"), packets: join(root, "packets"), overflowBytes: 65536 });
    const first = await store.create(), second = await store.create();
    await store.commit(first.id, { revision: first.manifest.revision, order: ["a"], writes: [{ id: "a", origins: [], bytes: Uint8Array.of(1) }] }, "alice");
    await store.commit(second.id, { revision: second.manifest.revision, order: ["b"], writes: [{ id: "b", origins: [], bytes: Uint8Array.of(2) }] }, "bob");
    await store.close();
    const removed = await run(["clean", "--thread", first.id], { ZINC_CONFIG: config });
    expect(removed).toMatchObject({ code: 0 }); expect(removed.out).toContain(first.id);
    const reopened = await Store.open({ path: join(root, "zinc.db"), packets: join(root, "packets"), overflowBytes: 65536 });
    await expect(reopened.read(first.id)).rejects.toThrow(); expect(await reopened.read(second.id)).toBeTruthy(); await reopened.close();
    const db = await connect(join(root, "zinc.db"));
    await db.run("insert into packets values('pkt_orphan','[]','system','system',0,?)", Uint8Array.of(9));
    await db.run("insert into packets values('pkt_markdown','[]','agent','agent',0,?)", new TextEncoder().encode(`${JSON.stringify({ zinc: "text", format: "markdown", text: "# One\n\nTwo\n\nThree" })}\n`));
    await db.close();
    const ranged = await run(["packet", "read", "--packet", "pkt_markdown", "--from", "1", "--to", "2"], { ZINC_CONFIG: config });
    expect(ranged).toMatchObject({ code: 0 }); expect(ranged.out.trim()).toBe("Two");
    expect(await run(["clean", "--packet", "pkt_orphan"], { ZINC_CONFIG: config })).toMatchObject({ code: 0 });
    const check = await connect(join(root, "zinc.db")); expect(await (await check.prepare("select id from packets where id='pkt_orphan'")).get()).toBeFalsy(); await check.close();
  });
});
