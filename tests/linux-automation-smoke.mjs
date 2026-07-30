import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtimeDir = process.env.CODEX_APP_RUNTIME_DIR
  ? path.resolve(process.env.CODEX_APP_RUNTIME_DIR)
  : path.join(projectDir, "runtime", "codex-app");

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
    return new Promise((resolve) => {
      const id = this.nextId++;
      this.pending.set(id, resolve);
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  close() {
    this.child.kill();
  }
}

async function testNodeRepl() {
  const client = new McpClient(path.join(runtimeDir, "resources", "cua_node", "bin", "node_repl"));
  try {
    const initialized = await client.request("initialize", { protocolVersion: "2025-03-26" });
    assert.equal(initialized.result.serverInfo.name, "node_repl");
    await client.request("tools/call", {
      name: "js",
      arguments: { code: "const smokeValue = await Promise.resolve(41)" },
    });
    const result = await client.request("tools/call", {
      name: "js",
      arguments: { code: "smokeValue + 1" },
    });
    assert.equal(result.result.content[0].text, "42");
    const compatibility = await client.request("tools/call", {
      name: "js",
      arguments: {
        code:
          "nodeRepl.setResponseMeta({ smoke: true }); console.log((await nodeRepl.createElicitation()).action)",
      },
    });
    assert.equal(compatibility.result.content[0].text, "accept");
    assert.equal(compatibility.result._meta.smoke, true);
  } finally {
    client.close();
  }
}

async function testComputerUse() {
  const command = path.join(
    runtimeDir,
    "resources",
    "plugins",
    "openai-bundled",
    "plugins",
    "computer-use",
    "scripts",
    "linux-computer-use",
  );
  const client = new McpClient(command, {
    ...process.env,
    CODEX_LINUX_COMPUTER_USE: "1",
    DISPLAY: "",
    XAUTHORITY: "",
    XDG_SESSION_TYPE: "x11",
    XDG_RUNTIME_DIR: "",
    DBUS_SESSION_BUS_ADDRESS: "",
  });
  try {
    const tools = await client.request("tools/list");
    assert(tools.result.tools.some((tool) => tool.name === "computer_get_state"));
    const state = await client.request("tools/call", {
      name: "computer_get_state",
      arguments: {},
    });
    assert.equal(state.result.isError, undefined);
    assert.equal(state.result.content[1].mimeType, "image/png");
  } finally {
    client.close();
  }
}

await testNodeRepl();
await testComputerUse();
console.log("Linux automation smoke tests passed.");
