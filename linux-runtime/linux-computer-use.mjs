import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { startMcpServer, textResult } from "./mcp-stdio.mjs";

const execFileAsync = promisify(execFile);
const runtimeDir = path.dirname(fileURLToPath(import.meta.url));
const inputHelper = path.join(runtimeDir, "x11-input.py");
let active = false;

function requireEnabled() {
  if (process.env.CODEX_LINUX_COMPUTER_USE !== "1") {
    throw new Error("Linux Computer Use is disabled. Set CODEX_LINUX_COMPUTER_USE=1 and restart Codex.");
  }
  if ((process.env.XDG_SESSION_TYPE || "").toLowerCase() === "wayland") {
    throw new Error("Linux Computer Use currently supports X11 only.");
  }
  if (!process.env.DISPLAY) {
    throw new Error("Linux Computer Use requires an active X11 DISPLAY.");
  }
}

async function run(command, args, options = {}) {
  return execFileAsync(command, args, {
    timeout: options.timeout ?? 15_000,
    maxBuffer: options.maxBuffer ?? 4 * 1024 * 1024,
    encoding: "utf8",
  });
}

async function runInput(payload) {
  const child = execFile("python3", [inputHelper], {
    timeout: 15_000,
    maxBuffer: 1024 * 1024,
  });
  child.stdin.end(JSON.stringify(payload));
  return new Promise((resolve, reject) => {
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
      code === 0
        ? resolve(stdout.trim())
        : reject(new Error(stderr.trim() || `X11 input helper exited with code ${code}`));
    });
  });
}

async function displaySize() {
  const { stdout } = await run("xrandr", ["--current"]);
  const match = stdout.match(/current\s+(\d+)\s+x\s+(\d+)/);
  if (!match) {
    throw new Error("Unable to determine X11 display dimensions.");
  }
  return { width: Number(match[1]), height: Number(match[2]) };
}

async function windows() {
  const { stdout } = await run("wmctrl", ["-lG"]);
  return stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^(\S+)\s+\S+\s+(-?\d+)\s+(-?\d+)\s+(\d+)\s+(\d+)\s+\S+\s+(.*)$/);
      return match
        ? {
            id: match[1],
            x: Number(match[2]),
            y: Number(match[3]),
            width: Number(match[4]),
            height: Number(match[5]),
            title: match[6],
          }
        : { raw: line };
    });
}

async function clientOrigin(windowId) {
  const { stdout } = await run("xwininfo", ["-id", windowId]);
  const x = stdout.match(/Absolute upper-left X:\s+(-?\d+)/);
  const y = stdout.match(/Absolute upper-left Y:\s+(-?\d+)/);
  return x && y ? { clientX: Number(x[1]), clientY: Number(y[1]) } : {};
}

async function windowsWithClientOrigins() {
  const openWindows = await windows();
  return Promise.all(
    openWindows.map(async (window) =>
      window.id ? { ...window, ...(await clientOrigin(window.id).catch(() => ({}))) } : window,
    ),
  );
}

async function screenshotContent() {
  const directory = await mkdtemp(path.join(tmpdir(), "codex-linux-cua-"));
  const screenshotPath = path.join(directory, "screen.png");
  try {
    await run("gnome-screenshot", ["-f", screenshotPath], { timeout: 30_000 });
    const image = await readFile(screenshotPath);
    return { type: "image", data: image.toString("base64"), mimeType: "image/png" };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function validatePoint(x, y, size) {
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x >= size.width || y >= size.height) {
    throw new Error(`Coordinates (${x}, ${y}) are outside the ${size.width}x${size.height} display.`);
  }
}

const pointProperties = {
  x: { type: "integer", minimum: 0 },
  y: { type: "integer", minimum: 0 },
};

const tools = [
  {
    name: "computer_get_state",
    description: "Capture the X11 desktop and return display dimensions and open windows.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "computer_focus_window",
    description: "Focus an X11 window by the hexadecimal window ID returned by computer_get_state.",
    inputSchema: {
      type: "object",
      properties: { window_id: { type: "string" } },
      required: ["window_id"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_minimize_all",
    description: "Minimize all ordinary X11 application windows.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "computer_move",
    description: "Move the pointer to absolute screen coordinates.",
    inputSchema: { type: "object", properties: pointProperties, required: ["x", "y"], additionalProperties: false },
  },
  {
    name: "computer_click",
    description: "Click at absolute screen coordinates.",
    inputSchema: {
      type: "object",
      properties: { ...pointProperties, button: { type: "integer", minimum: 1, maximum: 3, default: 1 } },
      required: ["x", "y"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_drag",
    description: "Drag from one absolute screen coordinate to another.",
    inputSchema: {
      type: "object",
      properties: {
        from_x: { type: "integer", minimum: 0 },
        from_y: { type: "integer", minimum: 0 },
        to_x: { type: "integer", minimum: 0 },
        to_y: { type: "integer", minimum: 0 },
        button: { type: "integer", minimum: 1, maximum: 3, default: 1 },
      },
      required: ["from_x", "from_y", "to_x", "to_y"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_type",
    description: "Type text into the focused X11 application.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string" }, delay_ms: { type: "integer", minimum: 0, maximum: 1000 } },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_key",
    description: "Press an X11 key or shortcut using keysym names such as Control_L, Alt_L, Return, or Escape.",
    inputSchema: {
      type: "object",
      properties: { keys: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 8 } },
      required: ["keys"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_scroll",
    description: "Scroll vertically, optionally at absolute screen coordinates. Positive amounts scroll up.",
    inputSchema: {
      type: "object",
      properties: {
        amount: { type: "integer", minimum: -100, maximum: 100 },
        ...pointProperties,
      },
      required: ["amount"],
      additionalProperties: false,
    },
  },
  {
    name: "computer_wait",
    description: "Wait briefly before checking desktop state again.",
    inputSchema: {
      type: "object",
      properties: { milliseconds: { type: "integer", minimum: 0, maximum: 30000 } },
      required: ["milliseconds"],
      additionalProperties: false,
    },
  },
];

startMcpServer({
  name: "linux-computer-use",
  version: "0.1.0",
  tools,
  async callTool(name, args) {
    requireEnabled();
    if (active) {
      throw new Error("Another Linux Computer Use request is already active.");
    }
    active = true;
    try {
      if (name === "computer_get_state") {
        const [size, openWindows, pointerJson, image] = await Promise.all([
          displaySize(),
          windowsWithClientOrigins(),
          runInput({ action: "pointer" }),
          screenshotContent(),
        ]);
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({ display: size, pointer: JSON.parse(pointerJson), windows: openWindows }, null, 2),
            },
            image,
          ],
        };
      }
      if (name === "computer_focus_window") {
        await run("wmctrl", ["-ia", String(args.window_id)]);
      } else if (name === "computer_minimize_all") {
        const openWindows = await windows();
        for (const window of openWindows) {
          if (window.id && window.title !== "nemo-desktop") {
            await runInput({ action: "minimize", window_id: window.id });
          }
        }
      } else if (name === "computer_wait") {
        await new Promise((resolve) => setTimeout(resolve, Number(args.milliseconds)));
      } else if (name === "computer_scroll") {
        if ((args.x == null) !== (args.y == null)) {
          throw new Error("computer_scroll requires both x and y when either coordinate is provided.");
        }
        if (args.x != null) {
          const size = await displaySize();
          validatePoint(Number(args.x), Number(args.y), size);
          await runInput({ action: "move", x: Number(args.x), y: Number(args.y) });
        }
        await runInput({ action: "scroll", amount: Number(args.amount) });
      } else if (name === "computer_key") {
        await runInput({ action: "key", keys: args.keys.map(String) });
      } else if (name === "computer_type") {
        await runInput({ action: "type", text: String(args.text), delay_ms: Number(args.delay_ms) || 5 });
      } else {
        const size = await displaySize();
        if (name === "computer_move" || name === "computer_click") {
          validatePoint(Number(args.x), Number(args.y), size);
          await runInput({
            action: name === "computer_move" ? "move" : "click",
            x: Number(args.x),
            y: Number(args.y),
            button: Number(args.button) || 1,
          });
        } else if (name === "computer_drag") {
          validatePoint(Number(args.from_x), Number(args.from_y), size);
          validatePoint(Number(args.to_x), Number(args.to_y), size);
          await runInput({
            action: "drag",
            from_x: Number(args.from_x),
            from_y: Number(args.from_y),
            to_x: Number(args.to_x),
            to_y: Number(args.to_y),
            button: Number(args.button) || 1,
          });
        }
      }
      return textResult("ok");
    } finally {
      active = false;
    }
  },
});
