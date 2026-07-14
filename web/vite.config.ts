import { fileURLToPath, URL } from "node:url";
import stylex from "@stylexjs/unplugin";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

export default defineConfig({
  root: fileURLToPath(new URL(".", import.meta.url)),
  resolve: { alias: { "~": fileURLToPath(new URL("./src", import.meta.url)) } },
  plugins: [stylex.vite(), solid()],
  optimizeDeps: { include: ["lexical", "@lexical/code", "@lexical/extension", "@lexical/rich-text"] },
  build: { outDir: "../dist/client", emptyOutDir: true },
});
