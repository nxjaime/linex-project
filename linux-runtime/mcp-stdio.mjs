import readline from "node:readline";

const hostProcess = process;

export function startMcpServer({ name, version, tools, callTool }) {
  const toolMap = new Map(tools.map((tool) => [tool.name, tool]));

  function send(message) {
    hostProcess.stdout.write(`${JSON.stringify(message)}\n`);
  }

  async function handle(message) {
    if (message.id == null) {
      return;
    }

    try {
      switch (message.method) {
        case "initialize":
          send({
            jsonrpc: "2.0",
            id: message.id,
            result: {
              protocolVersion: message.params?.protocolVersion ?? "2025-03-26",
              capabilities: { tools: {} },
              serverInfo: { name, version },
            },
          });
          return;
        case "ping":
          send({ jsonrpc: "2.0", id: message.id, result: {} });
          return;
        case "tools/list":
          send({ jsonrpc: "2.0", id: message.id, result: { tools } });
          return;
        case "tools/call": {
          const toolName = message.params?.name;
          if (!toolMap.has(toolName)) {
            throw new Error(`Unknown tool: ${toolName}`);
          }
          const result = await callTool(toolName, message.params?.arguments ?? {}, message.params ?? {});
          send({ jsonrpc: "2.0", id: message.id, result });
          return;
        }
        default:
          send({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32601, message: `Method not found: ${message.method}` },
          });
      }
    } catch (error) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
          isError: true,
        },
      });
    }
  }

  const lines = readline.createInterface({
    input: hostProcess.stdin,
    crlfDelay: Infinity,
    terminal: false,
  });
  let requestQueue = Promise.resolve();

  lines.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) {
      return;
    }
    try {
      const message = JSON.parse(trimmed);
      requestQueue = requestQueue
        .then(() => handle(message))
        .catch((error) => {
          hostProcess.stderr.write(`MCP request failed: ${error instanceof Error ? error.message : String(error)}\n`);
        });
    } catch (error) {
      hostProcess.stderr.write(`Invalid MCP message: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  });
}

export function textResult(text, extra = {}) {
  return {
    content: [{ type: "text", text: String(text) }],
    ...extra,
  };
}
