import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createThread_ } from "~/lib/db";
import { continueContext } from "./loop";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

async function fixture(respondScript: string, allowlist: string[]) {
  const root = await mkdtemp(join(tmpdir(), "zinc-loop-test-"));
  roots.push(root);

  const scriptPath = join(root, "respond.js");
  await writeFile(scriptPath, respondScript, "utf8");
  await chmod(scriptPath, 0o755);

  await writeFile(join(root, "turn.md"), `---
circuitry "0.10.0"

in { context $context; cwd $cwd }

respond source="./respond.js" "$context" {
  out { response ?response; circuitry ?circuitry }
}

out { response ?response; circuitry ?circuitry }
---
## Instructions
n/a
`, "utf8");

  const store = join(root, "zinc.db");
  await writeFile(join(root, "config.kdl"), `store "${store}"
turn "${join(root, "turn.md")}"
zinc-dir "${root}"
shell "sh"
${allowlist.length ? `allowlist {\n${allowlist.map((c) => `  ${c}`).join("\n")}\n}` : ""}
`, "utf8");

  process.env.ZINC_CONFIG = join(root, "config.kdl");
  return { store };
}

const RETURN_SHELL_COMMAND = (cmd: string) => `#!/usr/bin/env bun
const kdl = 'circuitry "0.10.0"\\nrun source="$shell" "-c" "${cmd}"\\n';
console.log('circuitry ' + JSON.stringify(kdl));
`;

const RETURN_RESPONSE = `#!/usr/bin/env bun
console.log('response "ok"');
`;

describe("continueContext allowlist policy", () => {
  it("gates the configured shell's command head, not the shell binary itself", async () => {
    const { store } = await fixture(RETURN_SHELL_COMMAND("git status"), ["git"]);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).not.toContain("not in the allowlist");
  });

  it("rejects a shell command whose head is not on the allowlist", async () => {
    const { store } = await fixture(RETURN_SHELL_COMMAND("rm -rf /"), ["git"]);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).toContain("command 'rm' is not in the allowlist");
  });

  it("does not gate the turn's own declared source, even though it is not on the allowlist", async () => {
    const { store } = await fixture(RETURN_RESPONSE, ["git"]);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).not.toContain("not in the allowlist");
    expect(result.mdx).toContain("ok");
  });
});
