import { join } from "@std/path";
import { execute } from "../../circuitry/mod.ts";

const home = await Deno.makeTempDir({ prefix: "zinc-bench-home-" });
Deno.env.set("HOME", home);
const root = await Deno.makeTempDir({ prefix: "zinc-bench-" });
const core = new URL("../core", import.meta.url).pathname;

const append = await source(
  "append.md",
  `\`\`\`luau
local D=require('@database')(require('@authority')) D.delete('append') local db=D.open('append') local run=db.nextRun()
for idx=1,1000 do db.append(run,'bench',{idx=idx,text='deterministic retrieval value'}) end
local result=db.snapshot() db.close() D.delete('append') return result
\`\`\``,
);
const recall = await source(
  "recall.md",
  `\`\`\`luau
local D=require('@database')(require('@authority')) D.delete('recall') local db=D.open('recall') local run=db.nextRun()
for idx=1,1000 do db.append(run,'bench',{idx=idx,text=idx%2==0 and 'writes are allowed' or 'writes are not allowed'}) end
local result=db.recall('writes allowed',db.snapshot(),999,{}) db.close() D.delete('recall') return #result
\`\`\``,
);

Deno.bench("append 1,000 slices", async () => {
  await execute(append, { sealed: [append, core] });
});
Deno.bench("Porter recall over 1,000 slices", async () => {
  await execute(recall, { sealed: [recall, core] });
});

async function source(name: string, text: string): Promise<string> {
  const path = join(root, name);
  await Deno.writeTextFile(path, text);
  return path;
}
