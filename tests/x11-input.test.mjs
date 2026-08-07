import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helperPath = path.join(projectDir, "linux-runtime", "x11-input.py");
const helperSource = await readFile(helperPath, "utf8");
assert.match(helperSource, /X\.XSync\.argtypes/);
assert.match(helperSource, /X\.XSync\(display, False\)/);

async function runInput(payload) {
  const child = spawn("python3", [helperPath], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(JSON.stringify(payload));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("Timed out waiting for X11 input helper: " + stderr));
    }, 10_000);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(stderr || "X11 input helper failed with code " + code));
      } else {
        resolve(stdout.trim() ? JSON.parse(stdout) : null);
      }
    });
  });
}

const { stdout: xrandr } = await execFileAsync("xrandr", ["--current"]);
const match = xrandr.match(/current\s+(\d+)\s+x\s+(\d+)/);
assert(match, "The active X11 display dimensions were not reported.");
const width = Number(match[1]);
const height = Number(match[2]);
const points = [
  { x: 100, y: 100 },
  { x: Math.min(550, width - 2), y: Math.min(268, height - 2) },
  { x: width - 2, y: height - 2 },
];

for (const point of points) {
  await runInput({ action: "move", ...point });
  const actual = await runInput({ action: "pointer" });
  assert.deepEqual(actual, point, `X11 pointer readback differed at ${JSON.stringify(point)}`);
}

console.log("X11 input coordinate tests passed.");
