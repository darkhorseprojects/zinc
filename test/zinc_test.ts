import { assertEquals } from "@std/assert";
import { join } from "@std/path";
import { execute } from "../../circuitry/mod.ts";

const core = new URL("../core", import.meta.url).pathname;

Deno.test("Database stores slices, bounded overflow, recall, and child ownership", async () => {
  await withHome(async (home) => {
    const main = await fixture(
      "main.md",
      `\`\`\`luau
local D=require('@database')(require('@authority')) local fs=require('@fs')
local root=D.open('test') local run=root.nextRun()
local first=root.append(run,'user',{text='writes are allowed'})
local second=root.append(run,'assistant',{text='writes are not allowed'})
root.trail(second,{first})
local child=D.child() local childRun=child.nextRun()
local huge=string.rep('x',40000) local spilled=child.append(childRun,'tool',{text=huge})
local bounded=child.recent(child.snapshot(),999,65536)[1].value local path=bounded.overflow
D.merge(root,child)
local recalled=root.recall('writes allowed',root.snapshot(),999,{})
local merged=root.read(spilled+second)
root.close()
return {first=first,second=second,overflow=#bounded.tail<40000,pathExists=fs.exists(path),merged=#merged.text,recall=#recalled}
\`\`\``,
    );
    const value = await execute(main, { sealed: [main, core] });
    assertEquals(value, { first: 1, second: 2, overflow: true, pathExists: true, merged: 40000, recall: 2 });
    await Deno.remove(home, { recursive: true });
  });
});

Deno.test("Environment wraps files, HTTP, and command headers", async () => {
  await withHome(async () => {
    const main = await fixture(
      "main.md",
      `\`\`\`luau
local env=require('@env') local denied=pcall(env.shell,'git push origin main')
local result=env.shell('printf zinc')
return {fields={guide=env.guide~=nil,files=env.files~=nil,http=env.http~=nil,shell=type(env.shell)=='function'},denied=denied,code=result.code,stdout=result.stdout}
\`\`\``,
    );
    assertEquals(await execute(main, { sealed: [main, core] }), {
      fields: { guide: true, files: true, http: true, shell: true },
      denied: false,
      code: 0,
      stdout: "zinc",
    });
  });
});

Deno.test("Agent exposes five fields and completes a native Responses request", async () => {
  await withHome(async () => {
    const port = 30000;
    let server: Deno.HttpServer;
    let requests = 0;
    try {
      server = Deno.serve({ hostname: "127.0.0.1", port, onListen() {} }, async (request) => {
        const body = await request.json() as { input: { type?: string }[] };
        requests += 1;
        if (requests === 1) {
          return Response.json({
            output: [{
              type: "function_call",
              name: "circuitry",
              call_id: "call-1",
              arguments: JSON.stringify({ document: "```luau\\nreturn 42\\n```" }),
            }],
          });
        }
        const continued = body.input.some((item) => item.type === "function_call_output");
        return Response.json({
          output: [{
            type: "message",
            content: [{ type: "output_text", text: `continued:${continued}` }],
          }],
        });
      });
    } catch {
      return;
    }
    try {
      const root = await Deno.makeTempDir({ prefix: "zinc-agent-test-" });
      const user = join(root, "user.md");
      const main = join(root, "main.md");
      await Deno.writeTextFile(user, "# User\n\n| field | value |\n| --- | --- |\n| name | Test |\n");
      await Deno.writeTextFile(
        main,
        `\`\`\`luau
local agent=require('@agent') local fields={} for field in pairs(agent) do table.insert(fields,field) end table.sort(fields)
local run=agent.ask('hello') return {fields=fields,answer=agent.read(run)}
\`\`\``,
      );
      assertEquals(
        await execute(main, { sealed: [main, user, core, new URL("../agent.md", import.meta.url).pathname] }),
        {
          fields: ["ask", "discard", "merge", "name", "read"],
          answer: "continued:true",
        },
      );
      assertEquals(requests, 2);
    } finally {
      await server.shutdown();
    }
  });
});

Deno.test("Builder installs atomically and removes Agent source", async () => {
  await withHome(async (home) => {
    const main = await fixture(
      "main.md",
      `\`\`\`luau
local b=require('@builder') local fs=require('@fs')
local source='# Helper\\n\\n\`\`\`luau\\nreturn table.freeze({name="helper"})\\n\`\`\`'
local path=b.install('helper',source) local present=fs.exists(path) b.remove('helper')
return {present=present,removed=not fs.exists(path)}
\`\`\``,
    );
    assertEquals(await execute(main, { sealed: [main, core] }), { present: true, removed: true });
    await Deno.remove(home, { recursive: true });
  });
});

async function fixture(name: string, source: string): Promise<string> {
  const root = await Deno.makeTempDir({ prefix: "zinc-test-" });
  const path = join(root, name);
  await Deno.writeTextFile(path, source);
  return path;
}

async function withHome<T>(run: (home: string) => Promise<T>): Promise<T> {
  const previous = Deno.env.get("HOME");
  const home = await Deno.makeTempDir({ prefix: "zinc-home-" });
  Deno.env.set("HOME", home);
  try {
    return await run(home);
  } finally {
    if (previous === undefined) Deno.env.delete("HOME");
    else Deno.env.set("HOME", previous);
  }
}
