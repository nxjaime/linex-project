import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, mkdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const installScript = path.join(projectDir, "scripts", "install-linux-automation.js");
const sourceDir = path.join(projectDir, "linux-runtime");
const installDir = await mkdtemp(path.join(os.tmpdir(), "linex-installer-test-"));
const bundledDir = path.join(installDir, "resources", "plugins", "openai-bundled");
const marketplacePath = path.join(bundledDir, ".agents", "plugins", "marketplace.json");

async function seedPlugin(name) {
  const pluginDir = path.join(bundledDir, "plugins", name, ".codex-plugin");
  await mkdir(pluginDir, { recursive: true });
  await writeFile(
    path.join(pluginDir, "plugin.json"),
    JSON.stringify({
      name,
      description: name,
      keywords: [],
      mcpServers: "./.mcp.json",
      interface: { shortDescription: name, longDescription: name },
    }),
  );
}

try {
  await mkdir(path.dirname(marketplacePath), { recursive: true });
  await writeFile(
    marketplacePath,
    JSON.stringify({
      plugins: [
        { name: "browser", source: { source: "local", path: "./plugins/browser" } },
        { name: "chrome", source: { source: "local", path: "./plugins/chrome" } },
      ],
    }),
  );
  await seedPlugin("browser");
  await seedPlugin("computer-use");

  await execFileAsync(process.execPath, [installScript, installDir, sourceDir]);
  const marketplace = JSON.parse(await readFile(marketplacePath, "utf8"));
  const names = marketplace.plugins.map((plugin) => plugin.name);
  assert(names.includes("browser"));
  assert(names.includes("chrome"));
  console.log("Linux automation installer Chrome-preservation test passed.");
} finally {
  await rm(installDir, { recursive: true, force: true });
}
