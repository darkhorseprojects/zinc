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

async function fixture(respondScript: string, allowlist: string[], out = "reasoning ?reasoning; response ?response; circuitry ?circuitry") {
  const root = await mkdtemp(join(tmpdir(), "zinc-loop-test-"));
  roots.push(root);

  const scriptPath = join(root, "respond.js");
  await writeFile(scriptPath, respondScript, "utf8");
  await chmod(scriptPath, 0o755);

  await writeFile(join(root, "turn.md"), `---
circuitry "0.10.0"

in { context $context; cwd $cwd }

respond source="./respond.js" "$context" {
  out { ${out} }
}

out { ${out} }
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

const RETURN_TWO_COMMANDS = `#!/usr/bin/env bun
if ((process.argv[2] ?? "").includes("second")) {
  console.log('response "done"');
} else {
  for (const cmd of ["echo first", "echo second"]) {
    const kdl = 'circuitry "0.10.0"\\nrun source="$shell" "-c" "' + cmd + '"\\n';
    console.log('circuitry ' + JSON.stringify(kdl));
  }
}
`;

const RETURN_RESPONSE_THEN_CIRCUITRY = `#!/usr/bin/env bun
if ((process.argv[2] ?? "").includes("tool-output")) {
  console.log('response "done"');
} else {
  console.log('response "checking"');
  const kdl = 'circuitry "0.10.0"\\nrun source="$shell" "-c" "echo tool-output"\\n';
  console.log('circuitry ' + JSON.stringify(kdl));
}
`;

const RETURN_REASONING_THEN_RESPONSE = `#!/usr/bin/env bun
if ((process.argv[2] ?? "").includes("thinking")) {
  console.log('response "done"');
} else {
  console.log('reasoning "thinking"');
}
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

  it("runs multiple returned circuitry documents from one turn", async () => {
    const { store } = await fixture(RETURN_TWO_COMMANDS, ["echo"]);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).toContain("first");
    expect(result.mdx).toContain("second");
  });

  it("continues when circuitry is the last terminal output, regardless of out declaration order", async () => {
    for (const out of ["reasoning ?reasoning; response ?response; circuitry ?circuitry", "circuitry ?circuitry; response ?response; reasoning ?reasoning"]) {
      const { store } = await fixture(RETURN_RESPONSE_THEN_CIRCUITRY, ["echo"], out);
      const thread = await createThread_(store);
      const result = await continueContext({ threadId: thread.id, input: "go" }, store);
      expect(result.mdx).toContain("tool-output");
      expect(result.mdx).toContain("done");
    }
  });

  it("continues after reasoning-only output", async () => {
    const { store } = await fixture(RETURN_REASONING_THEN_RESPONSE, []);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).toContain("thinking");
    expect(result.mdx).toContain("done");
  });

  it("does not gate the turn's own declared source, even though it is not on the allowlist", async () => {
    const { store } = await fixture(RETURN_RESPONSE, ["git"]);
    const thread = await createThread_(store);
    const result = await continueContext({ threadId: thread.id, input: "go" }, store);
    expect(result.mdx).not.toContain("not in the allowlist");
    expect(result.mdx).toContain("ok");
  });
});
