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
  sandbox.__nodeReplImport = createDynamicImporter();
  sandbox.__nodeReplOutput = output;
  return vm.createContext(sandbox);
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
    return textResult(evaluation.text, { _meta: evaluation.meta });
  },
});
