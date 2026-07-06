import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  resolve: {
    alias: {
      "~": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  optimizeDeps: {
    include: [
      "lexical",
      "@lexical/code",
      "@lexical/rich-text",
      "remark-gfm",
      "remark-mdx",
      "remark-parse",
      "unified",
    ],
  },
  build: {
    outDir: "dist/client",
    emptyOutDir: true,
  },
  plugins: [tailwindcss(), solid()],
});
