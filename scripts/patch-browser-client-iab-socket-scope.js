#!/usr/bin/env node
"use strict";

const fs = require("node:fs");

const clientPath = process.argv[2];
if (!clientPath) {
  throw new Error("Usage: patch-browser-client-iab-socket-scope.js /path/to/browser-client.mjs");
}

const socketDirMarker = "/*linexPerUserBrowserSocketDir*/";
const iabMarker = "/*linexIabSocketScope*/";
let source = fs.readFileSync(clientPath, "utf8");
let changed = false;

if (!source.includes(socketDirMarker)) {
  const resolverPattern =
    /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)=>\2==="win32"\?("(?:\\.|[^"\\])*codex-browser-use"):"\/tmp\/codex-browser-use"/g;
  const matches = [...source.matchAll(resolverPattern)];
  if (matches.length !== 1) {
    if (source.includes("/tmp/codex-browser-use")) {
      throw new Error(
        `Browser Use socket resolver drifted: expected one resolver, found ${matches.length}`,
      );
    }
  } else {
    const [target, resolver, platform, windowsSocket] = matches[0];
    const userInfoImport =
      'import{userInfo as linexBrowserUseUserInfo}from"node:os";';
    const helper =
      `function linexBrowserUseSocketDir(){let e=globalThis.nodeRepl?.env?.CODEX_BROWSER_USE_SOCKET_DIR;` +
      `if(typeof e==="string"&&e.length>0)return e;let t=linexBrowserUseUserInfo().uid;` +
      `if(Number.isInteger(t)&&t>=0)return \`/tmp/codex-browser-use-\${t}\`;` +
      `throw Error("Browser Use cannot resolve a per-user Linux socket directory")} ${socketDirMarker}\n`;
    const replacement =
      `${resolver}=${platform}=>${platform}==="win32"?${windowsSocket}:linexBrowserUseSocketDir()`;
    source = userInfoImport + helper + source.replace(target, replacement);
    changed = true;
  }
}

if (!source.includes(iabMarker)) {
  const listingPattern =
    /(?<listing>[A-Za-z_$][\w$]*)=async (?<options>[A-Za-z_$][\w$]*)=>\{let (?<directory>[A-Za-z_$][\w$]*)=(?<resolver>[A-Za-z_$][\w$]*)\(\k<options>\.platform\);return\(await (?<readDirectory>[A-Za-z_$][\w$]*)\(\k<directory>\)\)\.map\((?<entry>[A-Za-z_$][\w$]*)=>(?<pathModule>[A-Za-z_$][\w$]*)\.resolve\(\k<directory>,\k<entry>\)\)\}/g;
  const matches = [...source.matchAll(listingPattern)];
  if (matches.length === 1) {
    const target = matches[0][0];
    const { listing, options, directory, resolver, readDirectory, entry, pathModule } =
      matches[0].groups;
    const replacement =
      `${listing}=async ${options}=>{let ${directory}=${resolver}(${options}.platform);` +
      `return(await ${readDirectory}(${directory}))` +
      `.filter(${entry}=>!${entry}.startsWith("extension-")${iabMarker})` +
      `.map(${entry}=>${pathModule}.resolve(${directory},${entry}))}`;
    source = source.replace(target, replacement);
    changed = true;
  } else if (matches.length > 1) {
    throw new Error(`IAB Browser socket listing drifted: expected at most one target, found ${matches.length}`);
  }
}

if (changed) {
  fs.writeFileSync(clientPath, source, "utf8");
}
