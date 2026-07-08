#!/usr/bin/env bun
import { existsSync, mkdirSync, writeFileSync, chmodSync, rmSync, symlinkSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

const ROOT = resolve(dirname(Bun.main), "..");
const SYSTEM_LIB = join(homedir(), ".local", "lib", "zinc");
const SYSTEM_BIN_DIR = join(homedir(), ".local", "bin");
const SYSTEM_BIN = join(SYSTEM_BIN_DIR, "zn");

async function checkDependencies() {
  console.log("Checking path dependencies...");
  const proc = Bun.spawn(["bun", "--version"]);
  await proc.exited;
  if (proc.exitCode !== 0) {
    console.error("Error: 'bun' must be installed and on your PATH.");
    process.exit(1);
  }
  console.log("✓ Bun is installed");
}

async function runCmd(args, cwd) {
  console.log(`Running: ${args.join(" ")} in ${cwd}`);
  const proc = Bun.spawn(args, {
    cwd,
    stdout: "inherit",
    stderr: "inherit",
  });
  await proc.exited;
  if (proc.exitCode !== 0) {
    console.error(`Command failed with code ${proc.exitCode}: ${args.join(" ")}`);
    process.exit(1);
  }
}

async function main() {
  await checkDependencies();

  // 1. Install dependencies and build
  console.log("Installing root and web dependencies...");
  await runCmd(["bun", "install"], ROOT);
  await runCmd(["bun", "install"], join(ROOT, "web"));

  console.log("Building web assets and server...");
  await runCmd(["bun", "run", "build"], ROOT);

  // 2. Prepare system directory
  console.log(`Preparing system library directory: ${SYSTEM_LIB}`);
  rmSync(SYSTEM_LIB, { recursive: true, force: true });
  mkdirSync(SYSTEM_LIB, { recursive: true });
  mkdirSync(join(SYSTEM_LIB, "bin"), { recursive: true });
  mkdirSync(join(SYSTEM_LIB, "web"), { recursive: true });

  // 3. Copy built files
  console.log("Copying zn.js executable...");
  const znJsDest = join(SYSTEM_LIB, "bin", "zn.js");
  const znJsContent = readFileSync(join(ROOT, "bin", "zn.js"));
  writeFileSync(znJsDest, znJsContent);
  chmodSync(znJsDest, 0o755);

  console.log("Copying web files...");
  // Recursively copy web/dist and web/package.json
  copyDir(join(ROOT, "web", "dist"), join(SYSTEM_LIB, "web", "dist"));
  writeFileSync(join(SYSTEM_LIB, "web", "package.json"), readFileSync(join(ROOT, "web", "package.json")));

  // 4. Create CLI symlink in ~/.local/bin/zn
  console.log(`Creating symlink: ${SYSTEM_BIN} -> ${znJsDest}`);
  mkdirSync(SYSTEM_BIN_DIR, { recursive: true });
  try { rmSync(SYSTEM_BIN, { force: true }); } catch {}
  symlinkSync(znJsDest, SYSTEM_BIN);
  chmodSync(SYSTEM_BIN, 0o755);

  console.log("\nZinc successfully installed!");
  console.log("Verify by running: zn init");
}

function readFileSync(path) {
  const { readFileSync } = require("node:fs");
  return readFileSync(path);
}

function copyDir(src, dest) {
  const { readdirSync, statSync, copyFileSync } = require("node:fs");
  mkdirSync(dest, { recursive: true });
  const entries = readdirSync(src);
  for (const entry of entries) {
    const srcPath = join(src, entry);
    const destPath = join(dest, entry);
    if (statSync(srcPath).isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      copyFileSync(srcPath, destPath);
    }
  }
}

main().catch(err => {
  console.error("Installation failed:", err);
  process.exit(1);
});
