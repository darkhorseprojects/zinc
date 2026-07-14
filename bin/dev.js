#!/usr/bin/env edge
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const build = spawn("npm", ["run", "build"], { cwd: root, stdio: "inherit" });
if (await new Promise((done) => build.once("exit", done)) !== 0) process.exit(1);
const children = [
  spawn("npm", ["exec", "tsc", "--", "-p", "tsconfig.json", "--watch", "--preserveWatchOutput"], { cwd: root, stdio: "inherit" }),
  spawn("npm", ["run", "build:client", "--", "--watch"], { cwd: root, stdio: "inherit" }),
  spawn("edge", ["--watch", "dist/server.js"], { cwd: root, stdio: "inherit", env: process.env }),
];
const stop = () => children.forEach((child) => child.kill());
process.once("SIGINT", stop); process.once("SIGTERM", stop);
const code = await Promise.race(children.map((child) => new Promise((done) => child.once("exit", (value) => done(value ?? 1)))));
stop(); process.exit(Number(code));
