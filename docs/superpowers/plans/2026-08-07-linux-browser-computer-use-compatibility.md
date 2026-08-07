# Linux Browser and Computer Use Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make the Linux Mint port permanently compatible with the current Codex in-app browser, external Chrome extension, and X11 desktop-control surfaces, and block promotion when any required surface regresses.

**Architecture:** Keep upstream browser assets intact and implement Linux behavior in the Node bridge, X11 helper, installer, acceptance tests, and release controller. Every candidate is tested from its own runtime directory; only a human-approved candidate can enter the existing protected handoff.

**Tech Stack:** Node.js ES modules, Python 3 with Xlib/XTest via ctypes, Bash release scripts, GitHub Actions, MCP stdio, X11/Cinnamon utilities (xrandr, wmctrl, xwininfo, gnome-screenshot).

## Global Constraints

- Do not commit upstream application archives, extracted runtimes, browser profiles, credentials, screenshots, or personal data.
- Preserve the browser-client SHA-256 trust allowlist before granting access to the native browser pipe.
- Linux Computer Use supports X11 only; Wayland must return an explicit unsupported error.
- Browser and desktop acceptance tests must target CODEX_APP_RUNTIME_DIR when supplied.
- Candidate tests must leave /home/nickj/codex-app-mint/runtime/codex-app unchanged.
- Human approval and the existing protected handoff remain required after automated tests pass.
- Use test-first changes: each production change starts with a failing test that demonstrates the required behavior.

## File Map

| File | Responsibility |
| --- | --- |
| linux-runtime/node-repl.mjs | Persistent Node bridge, response metadata, post-submission hooks, browser side-effect emission. |
| tests/node-repl-browser-compat.test.mjs | Hermetic contract tests for bridge hooks, emissions, timeout, reset, and trust boundary. |
| scripts/install-linux-automation.js | Install Linux adapters and retain upstream browser/Chrome plugin surfaces in candidates. |
| tests/linux-automation-smoke.mjs | Candidate smoke checks for Node bridge capabilities and Computer Use discovery. |
| linux-runtime/x11-input.py | Root-coordinate pointer, click, drag, keyboard, scroll, and typing operations. |
| tests/x11-input.test.mjs | X11 helper contract tests using a fixture display and pointer readback. |
| tests/computer-use-acceptance.mjs | End-to-end X11 Computer Use acceptance against a selected candidate. |
| tests/browser-surface-acceptance.mjs | In-app browser and external Chrome connection report, without personal-data inspection. |
| scripts/linex-release.sh | Candidate build gate and promotion eligibility. |
| tests/linex-release.test.sh | Hermetic release-controller assertions. |
| README.md | Operator commands and browser/desktop verification procedure. |
| docs/compatibility.md | Durable verified-version record and tested-surface status. |
| .gitignore | Keep generated browser/candidate outputs local. |

---

### Task 1: Create the failing browser-bridge contract tests

**Files:**
- Create: tests/node-repl-browser-compat.test.mjs
- Modify: tests/linux-automation-smoke.mjs:40-75

**Interfaces:**
- Consumes: the generated candidate executable at $CODEX_APP_RUNTIME_DIR/resources/cua_node/bin/node_repl.
- Produces: a repeatable contract for nodeRepl.addAfterSubmittedCodeHook, nodeRepl.emitContentItem, and nodeRepl.emitImage.

- [ ] **Step 1: Write the failing test.** Start a fresh MCP client against the candidate node_repl, register a hook by evaluating:

~~~js
globalThis.hookHits = 0;
nodeRepl.addAfterSubmittedCodeHook({
  timeoutMs: 1000,
  run: async () => { globalThis.hookHits += 1; }
});
~~~

Then evaluate globalThis.hookHits in a second request and assert it is 1. Register an image/content emission callback in the test harness and assert the emitted payload is returned as a side effect. After js_reset, assert a new request does not run the old hook. Include a code path importing an untrusted browser fixture and assert the existing trust error remains.

- [ ] **Step 2: Run the test to verify it fails.**

Run: CODEX_APP_RUNTIME_DIR=/home/nickj/codex-app-mint/runtime/codex-app node tests/node-repl-browser-compat.test.mjs

Expected: FAIL with the missing nodeRepl.addAfterSubmittedCodeHook capability (the current observed failure is r.addAfterSubmittedCodeHook is not a function).

- [ ] **Step 3: Extend the smoke test assertion.** In tests/linux-automation-smoke.mjs, after the existing elicitation assertion, evaluate JSON.stringify({ hook: typeof nodeRepl.addAfterSubmittedCodeHook, content: typeof nodeRepl.emitContentItem, image: typeof nodeRepl.emitImage }) and assert all three values are "function".

- [ ] **Step 4: Run the targeted tests again.** Confirm both tests fail for the missing bridge methods, not for a syntax or fixture error.

- [ ] **Step 5: Commit the red tests.**

~~~bash
git add tests/node-repl-browser-compat.test.mjs tests/linux-automation-smoke.mjs
git commit -m "test: specify browser bridge compatibility contract"
~~~

### Task 2: Implement the persistent Node bridge compatibility layer

**Files:**
- Modify: linux-runtime/node-repl.mjs:10-70,135-170
- Modify: linux-runtime/mcp-stdio.mjs:1-90 only if side-effect transport needs a shared helper

**Interfaces:**
- Consumes: hook registrations shaped as { timeoutMs?: number, run: async () => void }.
- Produces: nodeRepl.addAfterSubmittedCodeHook({ timeoutMs, run }), nodeRepl.emitContentItem(value), and nodeRepl.emitImage(value) in the persistent context; hooks run after each completed evaluation and are cleared by js_reset.

- [ ] **Step 1: Add the smallest implementation that satisfies the red tests.** Keep a per-context afterSubmittedCodeHooks array and an emittedContent array. Validate that a hook has a callable run, clamp timeoutMs to the existing 1–300,000 ms execution range, and return an unsubscribe function. emitContentItem and emitImage append typed side-effect objects to the current response buffer without changing normal text output.

- [ ] **Step 2: Run the targeted tests to verify green.**

Run: CODEX_APP_RUNTIME_DIR=/home/nickj/codex-app-mint/runtime/codex-app node tests/node-repl-browser-compat.test.mjs

Expected: PASS, including hook execution, side-effect emission, reset isolation, and untrusted-import rejection.

- [ ] **Step 3: Run the smoke test.**

Run: CODEX_APP_RUNTIME_DIR=/home/nickj/codex-app-mint/runtime/codex-app node tests/linux-automation-smoke.mjs

Expected: PASS with all three browser bridge functions reported as available.

- [ ] **Step 4: Commit the bridge change.**

~~~bash
git add linux-runtime/node-repl.mjs linux-runtime/mcp-stdio.mjs
git commit -m "fix: add browser lifecycle bridge capabilities"
~~~

### Task 3: Preserve and verify external Chrome support

**Files:**
- Modify: scripts/install-linux-automation.js:32-48
- Create: tests/browser-surface-acceptance.mjs
- Modify: linux-runtime/browser-plugin.mcp.json

**Interfaces:**
- Consumes: the candidate browser plugin and the browser-client runtime with the trusted candidate hash.
- Produces: a JSON report with iab, chrome, and firefox statuses; unavailable external Chrome is reported as not_available, never as a false pass.

- [ ] **Step 1: Write the failing installer test.** Extend the shell release fixture to create a marketplace containing browser and chrome, run scripts/install-linux-automation.js, and assert both names remain. The current implementation is expected to fail because it filters chrome from marketplace.json.

- [ ] **Step 2: Run the test to verify red.**

Run: bash tests/linex-release.test.sh

Expected: FAIL at the assertion that the Chrome plugin remains available.

- [ ] **Step 3: Remove only the destructive Chrome filtering.** Keep the existing local Computer Use registration and browser plugin installation. Do not copy any profile or authentication state.

- [ ] **Step 4: Implement the browser-surface report.** tests/browser-surface-acceptance.mjs must load the candidate browser-client using its absolute path and trusted hash. It should select iab, call documentation(), list tabs, and perform only a read-only inspection. It should then attempt get("chrome")/extension selection; emit not_available with the connection error when no extension is connected. It must never read cookies, local storage, password stores, or profile files. Firefox is represented by the separate X11 acceptance result.

- [ ] **Step 5: Run the report against the current runtime.**

Run: CODEX_APP_RUNTIME_DIR=/home/nickj/codex-app-mint/runtime/codex-app node tests/browser-surface-acceptance.mjs

Expected: the in-app browser contract passes; Chrome is either verified or a clearly reported not_available environment condition.

- [ ] **Step 6: Commit the Chrome-preservation and report changes.**

~~~bash
git add scripts/install-linux-automation.js tests/browser-surface-acceptance.mjs linux-runtime/browser-plugin.mcp.json tests/linex-release.test.sh
git commit -m "fix: retain and report external Chrome support"
~~~

### Task 4: Make X11 pointer movement exact and testable

**Files:**
- Modify: linux-runtime/x11-input.py:7-114
- Create: tests/x11-input.test.mjs
- Modify: tests/computer-use-fixture.py:1-220 only to expose deterministic pointer/click state

**Interfaces:**
- Consumes: root coordinates { x: int, y: int } from the Computer Use MCP server.
- Produces: pointer readback in root coordinates after every warp and exact click/drag delivery.

- [ ] **Step 1: Add a failing pointer calibration test.** Launch the existing fixture under the active X11 display, call the helper with moves to {100,100}, {550,268}, and {display.width-2,display.height-2}, then query pointer. Assert exact equality for every point. Keep the test independent of the Codex window and do not click the user’s active browser.

- [ ] **Step 2: Run the test to verify red.**

Run: node tests/x11-input.test.mjs

Expected: FAIL at the first coordinate that differs, reproducing the observed (550,268) request landing at (384,264) or another concrete mismatch.

- [ ] **Step 3: Correct the ctypes and synchronization boundary.** Declare X.XQueryPointer and X.XWarpPointer argument/return types explicitly, call XSync(display, False) after warps and button events, and make pointer_position() return root coordinates only. Do not add a tolerance or silently apply a desktop-wide offset.

- [ ] **Step 4: Run the calibration test to verify green.**

Run: node tests/x11-input.test.mjs

Expected: PASS for all three coordinates on the active X11 display.

- [ ] **Step 5: Run the full Computer Use acceptance test.**

Run: CODEX_APP_RUNTIME_DIR=/home/nickj/codex-app-mint/runtime/codex-app node tests/computer-use-acceptance.mjs

Expected: PASS for movement, click, typing, modifier keys, scrolling, dragging, invalid-coordinate rejection, serialization, disabled mode, and Wayland rejection.

- [ ] **Step 6: Commit the X11 change.**

~~~bash
git add linux-runtime/x11-input.py tests/x11-input.test.mjs tests/computer-use-fixture.py
git commit -m "fix: make Linux computer use coordinates exact"
~~~

### Task 5: Add the permanent candidate release gate

**Files:**
- Modify: scripts/linex-release.sh:450-475,540-610,780-810
- Modify: tests/linex-release.test.sh:430-505
- Modify: .gitignore

**Interfaces:**
- Consumes: candidate runtime path, tests/linux-automation-smoke.mjs, tests/node-repl-browser-compat.test.mjs, tests/browser-surface-acceptance.mjs, and tests/computer-use-acceptance.mjs.
- Produces: a candidate that is eligible for approve only when every required automated test passes, while preserving the existing active symlink and rollback release.

- [ ] **Step 1: Write failing release assertions.** Add a fake candidate test command that fails browser compatibility and assert build-candidate exits nonzero while the live version remains unchanged. Add a success fixture that writes a browser-surface report and assert all four candidate checks receive the candidate CODEX_APP_RUNTIME_DIR. Add assertions that generated reports and browser test artifacts remain ignored.

- [ ] **Step 2: Run the release test to verify red.**

Run: bash tests/linex-release.test.sh

Expected: FAIL because the controller currently runs only the existing smoke and Computer Use acceptance commands.

- [ ] **Step 3: Add dedicated runner functions.** Implement run_browser_bridge_test, run_browser_surface_test, and update build-candidate to execute, in order: bridge contract, Linux smoke, Computer Use acceptance, and browser surface report. Each runner must pass CODEX_APP_RUNTIME_DIR="$candidate_dir"; a nonzero exit must abort before approval metadata is written.

- [ ] **Step 4: Add machine-readable candidate status.** Write only a local ignored report under the candidate directory containing test names, exit statuses, and UTC completion time. Do not include screenshots, tab URLs beyond origin-level diagnostics, or personal content.

- [ ] **Step 5: Run the release tests and syntax checks.**

Run: bash tests/linex-release.test.sh

Run: bash -n scripts/linex-release.sh

Expected: PASS with the active symlink unchanged in all candidate-failure cases.

- [ ] **Step 6: Commit the release gate.**

~~~bash
git add scripts/linex-release.sh tests/linex-release.test.sh .gitignore
git commit -m "test: gate candidates on browser and desktop compatibility"
~~~

### Task 6: Update operator documentation and compatibility records

**Files:**
- Modify: README.md:80-120
- Modify: docs/compatibility.md:1-40
- Modify: docs/compatibility.md status notes for the next approved version

**Interfaces:**
- Consumes: the final candidate test report and human verification result.
- Produces: clear operator instructions and a durable record distinguishing automated verification, unavailable Chrome environment, and owner-approved promotion.

- [ ] **Step 1: Write documentation assertions.** Extend tests/linex-release.test.sh to require commands and wording for browser bridge, in-app browser, external Chrome, Firefox-through-X11, and the human approval gate.

- [ ] **Step 2: Run the documentation assertions to verify red.**

Run: bash tests/linex-release.test.sh

Expected: FAIL until the new verification procedure is documented.

- [ ] **Step 3: Update README and compatibility guidance.** Document the exact candidate test commands, explain that Chrome may be not_available when its extension is not connected, and state that Firefox is tested through Computer Use. Do not claim a browser surface verified without its corresponding result.

- [ ] **Step 4: Run the full repository tests.**

Run: bash tests/linex-release.test.sh

Run: bash tests/linex-handoff.test.sh

Run: bash tests/port-source-options.test.sh

Run: node tests/runtime-path-options.test.mjs

Expected: all commands pass.

- [ ] **Step 5: Commit documentation.**

~~~bash
git add README.md docs/compatibility.md tests/linex-release.test.sh
git commit -m "docs: document browser and desktop compatibility gate"
~~~

### Task 7: Build, validate, and promote the newest upstream candidate

**Files:**
- Modify: docs/compatibility.md only after human verification
- Create locally only: /home/nickj/codex-app-mint/runtime/candidates/<version>/

**Interfaces:**
- Consumes: the official appcast, the completed compatibility gate, and the existing human approval/handoff commands.
- Produces: one promoted, tagged, rollback-protected Linux Mint build and a source-only GitHub compatibility record.

- [ ] **Step 1: Confirm the upstream version before downloading.**

Run: ./scripts/linex-release.sh check

Record the reported latest upstream version/build and compare it with the active runtime; do not guess the version from a prior conversation.

- [ ] **Step 2: Build the isolated candidate.**

Run: ./scripts/linex-release.sh build-candidate <reported-version>

Expected: candidate runtime exists under runtime/candidates/<reported-version>/codex-app, all automated gates pass, and runtime/codex-app still points to the prior approved release.

- [ ] **Step 3: Perform human verification.** Launch only the candidate and verify sign-in/conversations, a safe local task, terminal/Git diff, in-app browser, connected Chrome if available, and Firefox interaction through Computer Use. Do not enter credentials or personal data into test artifacts.

- [ ] **Step 4: Record explicit approval and promote.**

Run: ./scripts/linex-release.sh approve <reported-version>

Run: ./scripts/linex-release.sh promote <reported-version>

Expected: protected handoff switches the symlink only after the app closes and retains the prior release for rollback.

- [ ] **Step 5: Verify the health window and live version.**

Run: ./scripts/linex-release.sh handoff-status

Run: ./scripts/linex-release.sh check

Expected: handoff succeeds, the replacement remains healthy through the configured health window, and the active metadata matches the approved candidate.

- [ ] **Step 6: Record and tag the approved build.** Update docs/compatibility.md with version, internal build, date, browser surfaces, and any explicitly unavailable external Chrome condition. Commit and push only source and metadata:

~~~bash
git add docs/compatibility.md
git commit -m "docs: verify Mint app <upstream-version>"
git tag -a "mint-app-<upstream-version>" -m "Verified on Linux Mint: build <internal-build>"
git push origin main --follow-tags
~~~

- [ ] **Step 7: Verify rollback remains available.** Confirm the previous approved release remains under runtime/releases/ and that ./scripts/linex-release.sh rollback <previous-version> is still accepted by the controller without deleting either release.

## Self-Review Checklist

- The browser bridge contract, including post-submission hooks and side-effect emission, is covered by Tasks 1–2.
- In-app browser, Chrome availability, and Firefox-through-X11 are covered by Tasks 3–4 and the final live verification.
- Exact X11 root-coordinate behavior is tested without tolerances in Task 4.
- Candidate isolation, release gating, human approval, rollback, and status records are covered by Tasks 5–7.
- No task relies on a placeholder implementation or an unbounded browser/profile inspection.

