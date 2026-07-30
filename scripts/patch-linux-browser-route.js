#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");

const [asarDir] = process.argv.slice(2);
if (!asarDir) {
  console.error("Usage: patch-linux-browser-route.js <extracted-app-asar-dir>");
  process.exit(1);
}

const buildDir = path.join(asarDir, ".vite", "build");
const mainBundle = fs
  .readdirSync(buildDir)
  .find((name) => /^main-.*\.js$/.test(name));

if (!mainBundle) {
  throw new Error(`Main process bundle not found in ${buildDir}`);
}

const bundlePath = path.join(buildDir, mainBundle);
let source = fs.readFileSync(bundlePath, "utf8");
const marker =
  "}return this.recordDebugEvent({browserTabId:null,conversationId:e.conversationId,guestWebContentsId:null,kind:`session-route-missing`";
const replacement =
  "}let linuxPlaceholderRoute=this.sessionRoutes.get(`new-conversation`);if(process.platform===`linux`&&linuxPlaceholderRoute!=null&&this.delegate?.isWindowAlive(linuxPlaceholderRoute.windowId)===!0){this.captureSessionRouteForWindow({conversationId:e.conversationId,disposeAfterSessionActivity:!0,ownerWebContentsId:linuxPlaceholderRoute.ownerWebContentsId,windowId:linuxPlaceholderRoute.windowId}),Q().info(`IAB_LIFECYCLE aliased Linux placeholder session route`,{safe:{conversationId:e.conversationId,placeholderConversationId:linuxPlaceholderRoute.conversationId,windowId:linuxPlaceholderRoute.windowId},sensitive:{}});return!0}return this.recordDebugEvent({browserTabId:null,conversationId:e.conversationId,guestWebContentsId:null,kind:`session-route-missing`";

const occurrences = source.split(marker).length - 1;
const replacementOccurrences = source.split(replacement).length - 1;
if (occurrences === 1) {
  source = source.replace(marker, replacement);
} else if (occurrences !== 0 || replacementOccurrences !== 1) {
  throw new Error(`Expected one browser route patch point, found ${occurrences}`);
}

fs.writeFileSync(bundlePath, source);
console.error(`Patched Linux Browser session routing in ${bundlePath}`);
