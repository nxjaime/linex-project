import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { pathToFileURL } from "node:url";

const execFileAsync = promisify(execFile);
const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const patcher = path.join(projectDir, "scripts", "patch-browser-client-iab-socket-scope.js");
const tempDir = await mkdtemp(path.join(os.tmpdir(), "linex-browser-socket-scope-"));
const fixture = path.join(tempDir, "browser-client.mjs");
const source = `import { readdir as readDirectory } from "node:fs/promises";
import path from "node:path";
let resolver=platform=>platform==="win32"?"\\\\.\\\\pipe\\\\codex-browser-use":"/tmp/codex-browser-use";
let list=async options=>{let socketDirectory=resolver(options.platform);return(await readDirectory(socketDirectory)).map(entry=>path.resolve(socketDirectory,entry))};
export {resolver,list};
`;

try {
  await writeFile(fixture, source);
  await chmod(patcher, 0o755);
  await execFileAsync(process.execPath, [patcher, fixture]);
  const patched = await readFile(fixture, "utf8");
  assert.match(patched, /linexPerUserBrowserSocketDir/);
  assert.match(patched, /CODEX_BROWSER_USE_SOCKET_DIR/);
  assert.match(patched, /\/tmp\/codex-browser-use-\$\{t\}/);
  assert.match(patched, /filter\([^)]*startsWith\("extension-"\)/);
  const imported = await import(pathToFileURL(fixture).href);
  assert.equal(imported.resolver("linux"), `/tmp/codex-browser-use-${process.getuid()}`);
  const once = patched;
  await execFileAsync(process.execPath, [patcher, fixture]);
  assert.equal(await readFile(fixture, "utf8"), once);
} finally {
  await rm(tempDir, { recursive: true, force: true });
}

console.log("Browser socket scope patch tests passed.");
