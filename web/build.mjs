import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { transformAsync } from "@babel/core";
import stylex from "@stylexjs/babel-plugin";
import typescript from "@babel/preset-typescript";
import solid from "babel-preset-solid";
import { build, context } from "esbuild";

const root = dirname(fileURLToPath(import.meta.url));
const project = dirname(root);
const output = join(project, "dist", "client");
const watch = process.argv.includes("--watch");

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(join(root, "public"), output, { recursive: true });
await cp(join(root, "index.html"), join(output, "index.html"));

const options = {
  entryPoints: [join(root, "src", "main.tsx")],
  outdir: output,
  entryNames: "app",
  chunkNames: "assets/[name]-[hash]",
  assetNames: "assets/[name]-[hash]",
  bundle: true,
  splitting: true,
  format: "esm",
  platform: "browser",
  target: ["chrome120", "firefox120", "safari17.5"],
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  metafile: true,
  define: { "process.env.NODE_ENV": JSON.stringify(watch ? "development" : "production") },
  external: ["/fonts/*"],
  loader: { ".svg": "text", ".woff2": "file", ".woff": "file", ".ttf": "file" },
  plugins: [solidStylex()],
};

if (watch) {
  const builder = await context(options);
  await builder.watch();
  console.log("zinc client watching");
  await new Promise((resolve) => {
    const stop = async () => { await builder.dispose(); resolve(); };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
} else {
  await build(options);
}

async function assertSolidBundle() {
  const files = await clientJavaScript(output);
  const source = (await Promise.all(files.map((path) => readFile(path, "utf8")))).join("\n");
  for (const pattern of [/React\.createElement/, /react\/jsx-runtime/, /from["']react["']/]) {
    if (pattern.test(source)) throw new Error(`React emission in Zinc client: ${pattern}`);
  }
}

async function clientJavaScript(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? clientJavaScript(path) : entry.isFile() && path.endsWith(".js") ? [path] : [];
  }));
  return nested.flat();
}

function solidStylex() {
  const rules = new Map();
  return {
    name: "solid-stylex",
    setup(builder) {
      builder.onStart(() => rules.clear());
      builder.onLoad({ filter: /\.[jt]sx?$/ }, async ({ path }) => {
        if (!path.startsWith(`${root}/`)) return null;
        const result = await transformAsync(await readFile(path, "utf8"), {
          babelrc: false,
          configFile: false,
          filename: path,
          sourceMaps: watch ? "inline" : false,
          presets: [[solid, { generate: "dom", hydratable: false }], [typescript, { allExtensions: true, isTSX: /\.[jt]sx$/.test(path) }]],
          plugins: [[stylex, { importSources: ["@stylexjs/stylex"], treeshakeCompensation: false, unstable_moduleResolution: { type: "commonJS", rootDir: project } }]],
        });
        if (!result?.code) throw new Error(`Babel produced no output for ${path}`);
        rules.set(path, Array.isArray(result.metadata?.stylex) ? result.metadata.stylex : []);
        return { contents: result.code, loader: "js" };
      });
      builder.onEnd(async ({ errors }) => {
        if (errors.length) return;
        const css = stylex.processStylexRules([...rules.values()].flat(), { useLayers: false });
        await writeFile(join(output, "stylex.css"), css);
        await assertSolidBundle();
      });
    },
  };
}
