import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtimePathInterface = `const runtimeDir = process.env.CODEX_APP_RUNTIME_DIR
  ? path.resolve(process.env.CODEX_APP_RUNTIME_DIR)
  : path.join(projectDir, "runtime", "codex-app");`;

for (const testFile of ["linux-automation-smoke.mjs", "computer-use-acceptance.mjs"]) {
  const source = await readFile(path.join(projectDir, "tests", testFile), "utf8");
  assert.match(source, new RegExp(runtimePathInterface.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}
