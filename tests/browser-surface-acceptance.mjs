import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtimeDir = process.env.CODEX_APP_RUNTIME_DIR
  ? path.resolve(process.env.CODEX_APP_RUNTIME_DIR)
  : path.join(projectDir, "runtime", "codex-app");
const resourcesDir = path.join(runtimeDir, "resources");
const bundledDir = path.join(resourcesDir, "plugins", "openai-bundled");
const browserDir = path.join(bundledDir, "plugins", "browser");
const chromeDir = path.join(bundledDir, "plugins", "chrome");
const browserClientPath = path.join(browserDir, "scripts", "browser-client.mjs");
const marketplacePath = path.join(bundledDir, ".agents", "plugins", "marketplace.json");

const browserClient = await readFile(browserClientPath);
const browserHash = createHash("sha256").update(browserClient).digest("hex");
const browserPlugin = JSON.parse(await readFile(path.join(browserDir, ".codex-plugin", "plugin.json"), "utf8"));
const marketplace = JSON.parse(await readFile(marketplacePath, "utf8"));
const marketplaceNames = new Set(marketplace.plugins.map((plugin) => plugin.name));

assert.equal(typeof browserPlugin.name, "string");
assert.equal(marketplaceNames.has("browser"), true);

const report = {
  candidate: {
    runtime: runtimeDir,
    browser_client_sha256: browserHash,
    browser_plugin: browserPlugin.name,
  },
  iab: {
    status: "requires_live_app",
    detail: "Candidate assets and trusted browser client are present; live in-app verification is performed after launch.",
  },
  chrome: marketplaceNames.has("chrome") && await pathExists(chromeDir)
    ? {
        status: "requires_live_extension",
        detail: "Chrome plugin assets are retained; live verification requires a connected ChatGPT browser extension.",
      }
    : {
        status: "not_available",
        detail: "Chrome plugin assets are not present in this candidate.",
      },
  firefox: {
    status: "computer_use",
    detail: "Firefox is verified through the X11 Computer Use acceptance test.",
  },
};

console.log(JSON.stringify(report));

async function pathExists(target) {
  try {
    await readFile(target);
    return true;
  } catch {
    try {
      await import("node:fs/promises").then(({ access }) => access(target));
      return true;
    } catch {
      return false;
    }
  }
}
