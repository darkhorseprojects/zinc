#!/usr/bin/env edge
import { spawn } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const circuitry = resolve(root, "../circuitry");
const prefix = resolve(process.env.ZINC_INSTALL_PREFIX || `${homedir()}/.local`);
const temporary = mkdtempSync(join(tmpdir(), "zinc-install-"));
try {
  await run("edge", ["--version"]);
  await run("npm", ["ci"], circuitry);
  await run("npm", ["run", "build"], circuitry);
  await run("npm", ["ci"]);
  await run("npm", ["run", "check"]);

  const circuitryPackage = JSON.parse(readFileSync(join(circuitry, "package.json"), "utf8"));
  const circuitryArchive = `darkhorseprojects-circuitry-${circuitryPackage.version}.tgz`;
  await run("npm", ["pack", "--pack-destination", temporary], circuitry);

  const source = join(temporary, "zinc"), extracted = join(temporary, "circuitry");
  mkdirSync(source, { recursive: true });
  mkdirSync(extracted, { recursive: true });
  await run("tar", ["-xzf", join(temporary, circuitryArchive), "-C", extracted]);
  for (const name of ["dist", "bin", "agent", "defaults", "README.md", "SPEC.md", "LICENSE"]) cpSync(join(root, name), join(source, name), { recursive: true });
  cpSync(join(root, "node_modules"), join(source, "node_modules"), { recursive: true, dereference: true });
  const bundled = join(source, "node_modules", "@darkhorseprojects", "circuitry");
  rmSync(bundled, { recursive: true, force: true });
  mkdirSync(dirname(bundled), { recursive: true });
  cpSync(join(extracted, "package"), bundled, { recursive: true });
  const zincPackage = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  zincPackage.dependencies["@darkhorseprojects/circuitry"] = circuitryPackage.version;
  zincPackage.bundleDependencies = Object.keys(zincPackage.dependencies);
  writeFileSync(join(source, "package.json"), JSON.stringify(zincPackage, null, 2));
  await run("npm", ["pack", "--pack-destination", temporary], source);
  await run("npm", ["install", "--global", "--prefix", prefix, join(temporary, `zinc-${zincPackage.version}.tgz`)]);
  console.log(`installed Zinc under ${prefix}`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

async function run(command, args, cwd = root) {
  const code = await new Promise((done, fail) => {
    const child = spawn(command, args, { cwd, stdio: "inherit", env: process.env });
    child.once("error", fail);
    child.once("exit", (value) => done(value ?? 1));
  });
  if (code !== 0) throw new Error(`${command} failed with code ${code}`);
}
