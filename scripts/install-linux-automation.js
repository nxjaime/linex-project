#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");

const [installDir, sourceDir] = process.argv.slice(2);
if (!installDir || !sourceDir) {
  console.error("Usage: install-linux-automation.js <install-dir> <linux-runtime-source-dir>");
  process.exit(1);
}

function copy(sourceName, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(path.join(sourceDir, sourceName), destination);
}

function writeExecutable(destination, contents) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, contents, { mode: 0o755 });
}

const resourcesDir = path.join(installDir, "resources");
const cuaLibDir = path.join(resourcesDir, "cua_node", "lib");
const cuaBinDir = path.join(resourcesDir, "cua_node", "bin");
const marketplacePath = path.join(
  resourcesDir,
  "plugins",
  "openai-bundled",
  ".agents",
  "plugins",
  "marketplace.json",
);

if (fs.existsSync(marketplacePath)) {
  const marketplace = JSON.parse(fs.readFileSync(marketplacePath, "utf8"));
  marketplace.plugins = marketplace.plugins.filter((plugin) => plugin.name !== "chrome");
  if (!marketplace.plugins.some((plugin) => plugin.name === "computer-use")) {
    marketplace.plugins.push({
      name: "computer-use",
      source: {
        source: "local",
        path: "./plugins/computer-use",
      },
      policy: {
        installation: "AVAILABLE",
        authentication: "ON_INSTALL",
      },
      category: "Productivity",
    });
  }
  fs.writeFileSync(marketplacePath, `${JSON.stringify(marketplace, null, 2)}\n`);
}

writeExecutable(
  path.join(resourcesDir, "codex"),
  `#!/usr/bin/env bash
set -Eeuo pipefail
if [ -n "\${CODEX_CLI_PATH:-}" ] && [ -x "$CODEX_CLI_PATH" ]; then
  exec "$CODEX_CLI_PATH" "$@"
fi
exec codex "$@"
`,
);
copy("mcp-stdio.mjs", path.join(cuaLibDir, "mcp-stdio.mjs"));
copy("node-repl.mjs", path.join(cuaLibDir, "node-repl.mjs"));
writeExecutable(
  path.join(cuaBinDir, "node"),
  `#!/usr/bin/env bash
set -Eeuo pipefail
PRIMARY_NODE="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
if [ -x "$PRIMARY_NODE" ]; then
  exec "$PRIMARY_NODE" "$@"
fi
exec node "$@"
`,
);
writeExecutable(
  path.join(cuaBinDir, "codex"),
  `#!/usr/bin/env bash
set -Eeuo pipefail
if [ -n "\${CODEX_CLI_PATH:-}" ] && [ -x "$CODEX_CLI_PATH" ]; then
  exec "$CODEX_CLI_PATH" "$@"
fi
exec codex "$@"
`,
);
writeExecutable(
  path.join(cuaBinDir, "node_repl"),
  `#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_NODE="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
NODE_BIN="\${CODEX_BROWSER_USE_NODE_PATH:-$PRIMARY_NODE}"
if [ ! -x "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node)"
fi
exec "$NODE_BIN" "$SCRIPT_DIR/../lib/node-repl.mjs" "$@"
`,
);

const browserPluginDir = path.join(resourcesDir, "plugins", "openai-bundled", "plugins", "browser");
if (!fs.existsSync(browserPluginDir)) {
  throw new Error(`Bundled browser plugin not found: ${browserPluginDir}`);
}

const computerUsePluginDir = path.join(
  resourcesDir,
  "plugins",
  "openai-bundled",
  "plugins",
  "computer-use",
);
if (!fs.existsSync(computerUsePluginDir)) {
  throw new Error(`Bundled computer-use plugin not found: ${computerUsePluginDir}`);
}

copy("mcp-stdio.mjs", path.join(browserPluginDir, "scripts", "mcp-stdio.mjs"));
copy("browser-plugin.mcp.json", path.join(browserPluginDir, ".mcp.json"));
fs.rmSync(path.join(browserPluginDir, "scripts", "linux-computer-use"), { force: true });
fs.rmSync(path.join(browserPluginDir, "scripts", "linux-computer-use.mjs"), { force: true });
fs.rmSync(path.join(browserPluginDir, "scripts", "x11-input.py"), { force: true });
fs.rmSync(path.join(browserPluginDir, "skills", "linux-computer-use"), { recursive: true, force: true });

copy("mcp-stdio.mjs", path.join(computerUsePluginDir, "scripts", "mcp-stdio.mjs"));
copy("linux-computer-use.mjs", path.join(computerUsePluginDir, "scripts", "linux-computer-use.mjs"));
copy("x11-input.py", path.join(computerUsePluginDir, "scripts", "x11-input.py"));
fs.chmodSync(path.join(computerUsePluginDir, "scripts", "x11-input.py"), 0o755);
writeExecutable(
  path.join(computerUsePluginDir, "scripts", "linux-computer-use"),
  `#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

hydrate_desktop_session_env() {
  local pid=""
  pid="$(pgrep -u "$(id -u)" -f 'cinnamon-session-binary|gnome-session-binary|cinnamon --replace' | head -n 1 || true)"
  [ -n "$pid" ] || return 0
  [ -r "/proc/$pid/environ" ] || return 0

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      DISPLAY|XAUTHORITY|XDG_SESSION_TYPE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)
        if [ -z "\${!key:-}" ] && [ -n "$value" ]; then
          export "$key=$value"
        fi
        ;;
    esac
  done < <(tr '\\0' '\\n' < "/proc/$pid/environ")
}

hydrate_desktop_session_env

PRIMARY_NODE="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
NODE_BIN="\${CODEX_BROWSER_USE_NODE_PATH:-$PRIMARY_NODE}"
if [ ! -x "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node)"
fi
exec "$NODE_BIN" "$SCRIPT_DIR/linux-computer-use.mjs" "$@"
`,
);

copy(
  "linux-computer-use.SKILL.md",
  path.join(computerUsePluginDir, "skills", "computer-use", "SKILL.md"),
);

const pluginJsonPath = path.join(computerUsePluginDir, ".codex-plugin", "plugin.json");
const pluginJson = JSON.parse(fs.readFileSync(pluginJsonPath, "utf8"));
pluginJson.description = "Control Linux desktop apps from Codex through Computer Use.";
pluginJson.keywords = ["computer-use", "desktop-control", "linux", "x11", "automation"];
pluginJson.mcpServers = "./.mcp.json";
pluginJson.interface.shortDescription = "Control Linux apps from Codex";
pluginJson.interface.longDescription =
  "Linux Computer Use lets Codex inspect and control applications on an X11 desktop using screenshots, pointer input, keyboard input, scrolling, and window management.";
fs.writeFileSync(pluginJsonPath, `${JSON.stringify(pluginJson, null, 2)}\n`);

copy("computer-use-plugin.mcp.json", path.join(computerUsePluginDir, ".mcp.json"));
