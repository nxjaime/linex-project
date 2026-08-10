import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { inspect } from "node:util";
import vm from "node:vm";
import { createRequire } from "node:module";
import net from "node:net";
import os from "node:os";
import { startMcpServer, textResult } from "./mcp-stdio.mjs";

const hostProcess = process;
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_OUTPUT_CHARS = 1_000_000;
const moduleDirs = [];
let context;

function createContext() {
  const output = [];
  const sideEffects = [];
  const afterSubmittedCodeHooks = [];
  let responseMeta = {};
  const write = (value) => {
    output.push(typeof value === "string" ? value : inspect(value, { depth: 8, colors: false }));
  };
  const sandbox = {
    Buffer,
    URL,
    URLSearchParams,
    AbortController,
    AbortSignal,
    TextDecoder,
    TextEncoder,
    clearInterval,
    clearTimeout,
    console: {
      log: (...values) => write(values.map(formatValue).join(" ")),
      error: (...values) => write(values.map(formatValue).join(" ")),
      warn: (...values) => write(values.map(formatValue).join(" ")),
      info: (...values) => write(values.map(formatValue).join(" ")),
    },
    fetch,
    process,
    setInterval,
    setTimeout,
    structuredClone,
  };
  sandbox.global = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.nodeRepl = {
    config: {},
    fetch,
    async createElicitation() {
      return { action: "accept" };
    },
    addAfterSubmittedCodeHook({ timeoutMs = 10_000, run } = {}) {
      if (typeof run !== "function") {
        throw new TypeError("nodeRepl.addAfterSubmittedCodeHook requires a run function.");
      }
      const hook = {
        timeoutMs: Math.min(Math.max(Number(timeoutMs) || 10_000, 1), 300_000),
        run,
      };
      afterSubmittedCodeHooks.push(hook);
      return () => {
        const index = afterSubmittedCodeHooks.indexOf(hook);
        if (index >= 0) {
          afterSubmittedCodeHooks.splice(index, 1);
        }
      };
    },
    emitContentItem(value) {
      sideEffects.push(normalizeContentItem(value));
    },
    emitImage(value) {
      const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
      sideEffects.push({ type: "image", data: Buffer.from(bytes).toString("base64"), mimeType: "image/png" });
    },
    env: { ...hostProcess.env },
    tmpDir: os.tmpdir(),
    write,
    setResponseMeta(meta) {
      if (meta && typeof meta === "object") {
        responseMeta = { ...responseMeta, ...meta };
      }
    },
  };
  sandbox.__nodeReplGetResponseMeta = () => responseMeta;
  sandbox.__nodeReplSideEffects = sideEffects;
  sandbox.__nodeReplAfterSubmittedCodeHooks = afterSubmittedCodeHooks;
  sandbox.__nodeReplImport = createDynamicImporter();
  sandbox.__nodeReplOutput = output;
  return vm.createContext(sandbox);
}

function normalizeContentItem(value) {
  if (typeof value === "string") {
    return { type: "text", text: value };
  }
  if (value && typeof value === "object" && typeof value.type === "string") {
    return { ...value };
  }
  return { type: "text", text: formatValue(value) };
}

function formatValue(value) {
  return typeof value === "string" ? value : inspect(value, { depth: 8, colors: false });
}

function resetContext() {
  context = createContext();
}

function persistTopLevelDeclarations(code) {
  return code
    .replace(/\bimport\s*\(/g, "__nodeReplImport(")
    .replace(
      /(^|[;\n]\s*)(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/g,
      "$1globalThis.$2 =",
    );
}

function createDynamicImporter() {
  return async (specifier) => {
    if (specifier.endsWith("/browser-client.mjs") || specifier.endsWith("\\browser-client.mjs")) {
      await trustBrowserClient(specifier);
    }
    if (specifier.startsWith(".") || specifier.startsWith("/") || specifier.startsWith("file:")) {
      return import(specifier);
    }

    for (const directory of moduleDirs) {
      try {
        const requireFromDirectory = createRequire(`${directory}/package.json`);
        return import(requireFromDirectory.resolve(specifier));
      } catch {
        // Try the next configured module directory.
      }
    }
    return import(specifier);
  };
}

async function trustBrowserClient(specifier) {
  const trustedHashes = (hostProcess.env.NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S || "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  if (trustedHashes.length === 0) {
    throw new Error("Browser client trust hashes are not configured.");
  }
  const bytes = await readFile(specifier);
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (!trustedHashes.includes(digest)) {
    throw new Error(`Browser client SHA-256 is not trusted: ${digest}`);
  }
  context.nodeRepl.nativePipe = {
    createConnection(socketPath) {
      return new Promise((resolve, reject) => {
        const socket = net.createConnection(socketPath);
        const onError = (error) => {
          socket.removeListener("connect", onConnect);
          reject(error);
        };
        const onConnect = () => {
          socket.removeListener("error", onError);
          resolve(socket);
        };
        socket.once("error", onError);
        socket.once("connect", onConnect);
      });
    },
  };
  globalThis.nodeRepl = context.nodeRepl;
}

async function evaluate(code, timeoutMs) {
  context.__nodeReplOutput.length = 0;
  context.__nodeReplSideEffects.length = 0;
  const source = persistTopLevelDeclarations(code);
  let promise;

  try {
    const expression = new vm.Script(`(async () => (${source}\n))()`);
    promise = expression.runInContext(context, { timeout: timeoutMs });
  } catch {
    const statements = new vm.Script(`(async () => {\n${source}\n})()`);
    promise = statements.runInContext(context, { timeout: timeoutMs });
  }

  const timeout = new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error(`JavaScript execution timed out after ${timeoutMs} ms`)), timeoutMs);
    timer.unref();
  });
  const value = await Promise.race([promise, timeout]);
  for (const hook of [...context.__nodeReplAfterSubmittedCodeHooks]) {
    try {
      await Promise.race([
        Promise.resolve().then(() => hook.run()),
        new Promise((_, reject) => {
          const timer = setTimeout(
            () => reject(new Error(`after-submission hook timed out after ${hook.timeoutMs} ms`)),
            hook.timeoutMs,
          );
          timer.unref();
        }),
      ]);
    } catch (error) {
      context.nodeRepl.emitContentItem({
        type: "text",
        text: `Browser response hook failed: ${error instanceof Error ? error.message : String(error)}`,
      });
    }
  }
  const chunks = [...context.__nodeReplOutput];
  if (value !== undefined) {
    chunks.push(formatValue(value));
  }
  const result = chunks.join("\n");
  return {
    text:
      result.length > MAX_OUTPUT_CHARS
        ? `${result.slice(0, MAX_OUTPUT_CHARS)}\n[output truncated]`
        : result,
    sideEffects: [...context.__nodeReplSideEffects],
    meta: context.__nodeReplGetResponseMeta(),
  };
}

resetContext();

const tools = [
  {
    name: "js",
    description: "Execute JavaScript in a persistent Node.js session with top-level await.",
    inputSchema: {
      type: "object",
      properties: {
        code: { type: "string", description: "JavaScript source to execute." },
        timeout_ms: { type: "integer", minimum: 1, maximum: 300000 },
      },
      required: ["code"],
      additionalProperties: false,
    },
  },
  {
    name: "js_reset",
    description: "Reset the persistent JavaScript session.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "js_add_node_module_dir",
    description: "Add a directory used to resolve imported Node.js packages.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" } },
      required: ["path"],
      additionalProperties: false,
    },
  },
];

startMcpServer({
  name: "node_repl",
  version: "0.1.0-linux",
  tools,
  async callTool(name, args, callParams) {
    const requestMeta = callParams?._meta ?? args?._meta;
    if (requestMeta && typeof requestMeta === "object") {
      context.nodeRepl.requestMeta = requestMeta;
      if (globalThis.nodeRepl) {
        globalThis.nodeRepl.requestMeta = requestMeta;
      }
    }
    if (name === "js_reset") {
      resetContext();
      return textResult("JavaScript session reset.");
    }
    if (name === "js_add_node_module_dir") {
      if (!moduleDirs.includes(args.path)) {
        moduleDirs.push(args.path);
      }
      return textResult(args.path);
    }
    const timeoutMs = Math.min(Math.max(Number(args.timeout_ms) || DEFAULT_TIMEOUT_MS, 1), 300_000);
    const evaluation = await evaluate(String(args.code), timeoutMs);
    return {
      content: [
        ...(evaluation.text ? [{ type: "text", text: evaluation.text }] : []),
        ...evaluation.sideEffects,
      ],
      _meta: evaluation.meta,
    };
  },
});
