#!/usr/bin/env edge
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { resolve } from "node:path";

const prefix = resolve(process.env.ZINC_INSTALL_PREFIX || `${homedir()}/.local`);
const code = await new Promise((done, fail) => { const child = spawn("npm", ["uninstall", "--global", "--prefix", prefix, "zinc"], { stdio: "inherit" }); child.once("error", fail); child.once("exit", (value) => done(value ?? 1)); });
if (code !== 0) throw new Error(`npm uninstall failed with code ${code}`);
console.log("removed Zinc program files; user data was preserved");
