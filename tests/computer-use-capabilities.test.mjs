import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = path.join(projectDir, "linux-runtime", "linux-computer-use.mjs");

class Client {
  constructor(env) {
    this.child = spawn(process.execPath, [serverPath], { env, stdio: ["pipe", "pipe", "inherit"] });
    this.buffer = "";
    this.id = 1;
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
      const id = this.id++;
      const timer = setTimeout(() => reject(new Error(`Timed out: ${method}`)), 5000);
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  call(name) {
    return this.request("tools/call", { name, arguments: {} });
  }

  close() {
    this.child.kill();
  }
}

for (const sessionType of ["x11", "wayland"]) {
  const client = new Client({ ...process.env, CODEX_LINUX_COMPUTER_USE: "1", XDG_SESSION_TYPE: sessionType });
  try {
    const response = await client.call("computer_get_capabilities");
    assert.equal(response.result.isError, undefined);
    const report = JSON.parse(response.result.content[0].text);
    assert.equal(report.session_type, sessionType);
    assert.equal(typeof report.control_supported, "boolean");
    assert.equal(Array.isArray(report.available_backends), true);
  } finally {
    client.close();
  }
}

console.log("Computer Use capability tests passed.");
