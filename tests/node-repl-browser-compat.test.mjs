import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtimeDir = process.env.CODEX_APP_RUNTIME_DIR
  ? path.resolve(process.env.CODEX_APP_RUNTIME_DIR)
  : path.join(projectDir, "runtime", "codex-app");
const nodeRepl = path.join(runtimeDir, "resources", "cua_node", "bin", "node_repl");
const browserClient = path.join(runtimeDir, "resources", "plugins", "openai-bundled", "plugins", "browser", "scripts", "browser-client.mjs");

class McpClient {
  constructor(command, env = process.env) {
    this.child = spawn(command, [], { env, stdio: ["pipe", "pipe", "inherit"] });
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
    this.child.stdout.on("data", (chunk) => {
      this.buffer += chunk;
      let newline;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        if (!line) continue;
        const message = JSON.parse(line);
        this.pending.get(message.id)?.(message);
        this.pending.delete(message.id);
      }
    });
  }

  request(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("Timed out waiting for " + method));
      }, 10_000);
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  js(code) {
    return this.request("tools/call", { name: "js", arguments: { code } });
  }

  close() {
    this.child.kill();
  }
}

const client = new McpClient(nodeRepl, {
  ...process.env,
  NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S: "",
});

try {
  const initialized = await client.request("initialize", { protocolVersion: "2025-03-26" });
  assert.equal(initialized.result.serverInfo.name, "node_repl");

  const registration = await client.js(
    "globalThis.hookHits = 0; nodeRepl.addAfterSubmittedCodeHook({ timeoutMs: 1000, run: async () => { globalThis.hookHits += 1; nodeRepl.emitContentItem({ type: 'text', text: 'hook-side-effect' }); } }); 'registered'",
  );
  assert.equal(registration.result.isError, undefined);
  assert(registration.result.content.some((item) => item.text === "hook-side-effect"));

  const secondRequest = await client.js("globalThis.hookHits");
  assert.equal(secondRequest.result.isError, undefined);
  assert.equal(secondRequest.result.content[0].text, "1");
  assert(secondRequest.result.content.some((item) => item.text === "hook-side-effect"));

  const reset = await client.request("tools/call", { name: "js_reset", arguments: {} });
  assert.equal(reset.result.isError, undefined);
  const afterReset = await client.js("typeof globalThis.hookHits");
  assert.equal(afterReset.result.content[0].text, "undefined");

  const trustFailure = await client.js("await import(" + JSON.stringify(browserClient) + ")");
  assert.equal(trustFailure.result.isError, true);
  assert.match(trustFailure.result.content[0].text, /trusted|trust hashes/i);

  console.log("Node bridge browser compatibility tests passed.");
} finally {
  client.close();
}
