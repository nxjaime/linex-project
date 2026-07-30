import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixturePath = path.join(projectDir, "tests", "computer-use-fixture.py");
const inputHelperPath = path.join(projectDir, "linux-runtime", "x11-input.py");
const serverPath = path.join(
  projectDir,
  "runtime",
  "codex-app",
  "resources",
  "plugins",
  "openai-bundled",
  "plugins",
  "computer-use",
  "scripts",
  "linux-computer-use",
);

class McpClient {
  constructor(command, env) {
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
      this.pending.set(id, resolve);
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP request timed out: ${method} ${params.name ?? ""}`));
      }, 10_000);
      timer.unref();
      this.pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  }

  call(name, args = {}) {
    return this.request("tools/call", { name, arguments: args });
  }

  close() {
    this.child.kill();
  }
}

async function waitFor(check, message, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(message);
}

const tempDir = await mkdtemp(path.join(os.tmpdir(), "codex-computer-use-test-"));
const statePath = path.join(tempDir, "state.json");
const fixture = spawn("python3", [fixturePath], {
  env: { ...process.env, COMPUTER_USE_FIXTURE_STATE: statePath },
  stdio: "ignore",
});
const enabledEnv = {
  ...process.env,
  CODEX_LINUX_COMPUTER_USE: "1",
  XDG_SESSION_TYPE: "x11",
};
const client = new McpClient(serverPath, enabledEnv);

const readState = async () => JSON.parse(await readFile(statePath, "utf8"));
const readPointer = () =>
  new Promise((resolve, reject) => {
    const child = spawn("python3", [inputHelperPath], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      code === 0 ? resolve(JSON.parse(stdout)) : reject(new Error(stderr));
    });
    child.stdin.end(JSON.stringify({ action: "pointer" }));
  });

try {
  await waitFor(async () => {
    try {
      return await readState();
    } catch {
      return null;
    }
  }, "Fixture did not start");

  const { initial, fixtureWindow } = await waitFor(async () => {
    const state = await client.call("computer_get_state");
    const desktop = JSON.parse(state.result.content[0].text);
    const window = desktop.windows.find((item) => item.title === "Codex Computer Use Fixture");
    return window ? { initial: state, fixtureWindow: window } : null;
  }, "Fixture window was not discovered");
  assert.equal(initial.result.isError, undefined);
  assert.equal(initial.result.content[1].mimeType, "image/png");

  await client.call("computer_focus_window", { window_id: fixtureWindow.id });
  assert(Number.isFinite(fixtureWindow.clientX));
  assert(Number.isFinite(fixtureWindow.clientY));
  const originX = fixtureWindow.clientX;
  const originY = fixtureWindow.clientY;

  const pointerX = originX + 350;
  const pointerY = originY + 80;
  await client.call("computer_move", { x: pointerX, y: pointerY });
  assert.deepEqual(await readPointer(), { x: pointerX, y: pointerY });

  await client.call("computer_click", {
    x: originX + 155,
    y: originY + 130,
  });
  await waitFor(async () => (await readState()).button_clicks === 1, "Click was not delivered");

  await client.call("computer_click", {
    x: originX + 180,
    y: originY + 220,
  });
  await client.call("computer_type", { text: "codex123", delay_ms: 1 });
  await waitFor(async () => (await readState()).entry === "codex123", "Typing was not delivered");

  await client.call("computer_key", { keys: ["Control_L", "a"] });
  await waitFor(async () => {
    const events = (await readState()).key_events;
    return events.includes("Control_L") && events.includes("a");
  }, "Modifier shortcut was not delivered");
  await client.call("computer_key", { keys: ["Home"] });
  await client.call("computer_key", { keys: ["Shift_L", "End"] });
  await client.call("computer_type", { text: "replaced", delay_ms: 1 });
  await waitFor(async () => (await readState()).entry === "replaced", "Keyboard shortcut failed");

  await client.call("computer_scroll", {
    amount: -3,
    x: originX + 500,
    y: originY + 200,
  });
  await waitFor(async () => (await readState()).scroll_events >= 3, "Scrolling was not delivered");

  await client.call("computer_drag", {
    from_x: originX + 110,
    from_y: originY + 350,
    to_x: originX + 260,
    to_y: originY + 370,
  });
  await waitFor(async () => (await readState()).drag_events > 0, "Dragging was not delivered");

  const invalid = await client.call("computer_click", { x: -1, y: 0 });
  assert.equal(invalid.result.isError, true);
  assert.match(invalid.result.content[0].text, /outside/);

  const serializationStarted = Date.now();
  const firstWait = client.call("computer_wait", { milliseconds: 250 });
  const queuedWait = client.call("computer_wait", { milliseconds: 1 });
  const [firstWaitResult, queuedWaitResult] = await Promise.all([firstWait, queuedWait]);
  assert.equal(firstWaitResult.result.isError, undefined);
  assert.equal(queuedWaitResult.result.isError, undefined);
  assert(Date.now() - serializationStarted >= 240, "Desktop actions were not serialized");

  const disabled = new McpClient(serverPath, {
    ...process.env,
    CODEX_LINUX_COMPUTER_USE: "0",
    XDG_SESSION_TYPE: "x11",
  });
  try {
    const disabledResult = await disabled.call("computer_get_state");
    assert.equal(disabledResult.result.isError, true);
    assert.match(disabledResult.result.content[0].text, /disabled/);
  } finally {
    disabled.close();
  }

  const wayland = new McpClient(serverPath, {
    ...process.env,
    CODEX_LINUX_COMPUTER_USE: "1",
    XDG_SESSION_TYPE: "wayland",
  });
  try {
    const waylandResult = await wayland.call("computer_get_state");
    assert.equal(waylandResult.result.isError, true);
    assert.match(waylandResult.result.content[0].text, /X11 only/);
  } finally {
    wayland.close();
  }

  console.log("Computer Use acceptance tests passed.");
} finally {
  client.close();
  fixture.kill();
  await rm(tempDir, { recursive: true, force: true });
}
