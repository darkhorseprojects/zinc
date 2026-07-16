import { readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = dirname(fileURLToPath(import.meta.url));
const project = dirname(root);
const output = join(project, ".test-build");
const entries = (await readdir(root))
  .filter((name) => name.endsWith(".test.ts"))
  .map((name) => join(root, name));

await rm(output, { recursive: true, force: true });
await build({
  entryPoints: entries,
  outdir: output,
  entryNames: "[name]",
  bundle: true,
  packages: "external",
  platform: "node",
  format: "esm",
  target: "node24",
  sourcemap: "inline",
});
