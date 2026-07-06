import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");

const forbidden = [
  `turn.${"started"}`,
  `source.${"started"}`,
  `source.${"denied"}`,
  `source.${"requested"}`,
  `source.${"responded"}`,
  `assistant.${"delta"}`,
  `reasoning.${"delta"}`,
  `projection.${"committed"}`,
  `source.${"request"}`,
  `source.${"response"}`,
  `response.${"delta"}`,
];

describe("Zinc thread transport guard", () => {
  it("has no obsolete routes and exposes thread continuation transport", () => {
    expect(existsSync(resolve(root, `routes/api/run.ts`))).toBe(false);
    expect(existsSync(resolve(root, `routes/api/run/stream.ts`))).toBe(false);
    expect(existsSync(resolve(root, "routes/api/document.ts"))).toBe(false);
    expect(existsSync(resolve(root, "routes/api/document/continue/stream.ts"))).toBe(false);
    expect(existsSync(resolve(root, "server/routes/continueStream.ts"))).toBe(true);
  });

  it("does not reintroduce forbidden stream/event taxonomy in transport/runtime code", () => {
    const files = [
      resolve(root, "server/runtime/continueContext.ts"),
      resolve(root, "server/routes/continueStream.ts"),
    ];
    const haystack = files.map((file) => readFileSync(file, "utf8")).join("\n");

    for (const term of forbidden) expect(haystack).not.toContain(term);
  });
});