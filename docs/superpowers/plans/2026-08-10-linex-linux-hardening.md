# Linex Linux Hardening and Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Browser socket isolation, upstream fingerprinting, CI drift detection, Debian packaging, managed Node, and capability-based Computer Use diagnostics for Linex.

**Architecture:** Keep the existing shell build/release controller and human approval workflow. Add small reusable helpers rather than replacing the current port. Package creation is manual and non-mutating; managed Node is verified before bundling; Computer Use keeps X11 controls and adds a truthful capability/read-only Wayland surface.

**Tech Stack:** Bash, Python 3 standard library, Node.js ESM, Electron runtime, `dpkg-deb`, GitHub Actions.

## Global Constraints

- Human approval remains required before release promotion.
- Do not read browser profiles, cookies, passwords, or personal data.
- Do not auto-install or auto-promote packages.
- Preserve Linux Mint Cinnamon X11 behavior and existing acceptance tests.
- Verify downloaded managed Node archives with official SHA-256 manifests.

### Task 1: Browser socket isolation

**Files:**
- Create: `scripts/patch-browser-client-iab-socket-scope.js`
- Modify: `port-codex-app-mint.sh`
- Create: `tests/browser-client-iab-socket-scope.test.mjs`

- [ ] Write a fixture-based test for the unpatched resolver/listing, assert the patch adds a per-user resolver and filters extension sockets, then assert a second patch is byte-identical.
- [ ] Run the focused test and confirm it fails because the patch script is missing.
- [ ] Implement the patch with an explicit `CODEX_BROWSER_USE_SOCKET_DIR` override and `os.userInfo().uid` fallback.
- [ ] Invoke it during ASAR patching when the bundled Browser client exists; fail closed if the client contains Browser Use markers but has an unexpected resolver shape.
- [ ] Run the focused test and existing Browser tests.

### Task 2: Upstream release metadata and fingerprints

**Files:**
- Create: `scripts/upstream-release-info.py`
- Modify: `port-codex-app-mint.sh`
- Modify: `scripts/linex-release.sh`
- Create: `tests/upstream-release-info.test.sh`

- [ ] Write a local appcast/archive test for version/build selection and SHA-256/size output.
- [ ] Run it and confirm the helper is missing.
- [ ] Implement JSON output with version, build, archive URL, ETag, Last-Modified, Content-Length, local archive SHA-256, and byte size.
- [ ] Write `source-fingerprint.json` into each generated install directory and include its path in candidate reports.
- [ ] Validate the file path and JSON fields from the release controller without changing promotion semantics.
- [ ] Run focused and release tests.

### Task 3: Fingerprint-aware scheduled workflow

**Files:**
- Modify: `.github/workflows/check-release.yml`
- Modify: `docs/compatibility.md`
- Create: `tests/check-release-workflow.test.sh`

- [ ] Write a static workflow test requiring version/build and fingerprint fields, issue deduplication markers, and no automatic promotion/install commands.
- [ ] Run it and confirm the workflow does not yet satisfy the assertions.
- [ ] Update the workflow to call the metadata helper, include an identity marker in the issue, compare both version and build, and avoid duplicate open issues for the same identity.
- [ ] Document the new issue/metadata behavior.
- [ ] Run the workflow test and shell syntax checks.

### Task 4: Manual Debian package

**Files:**
- Create: `scripts/build-deb.sh`
- Create: `tests/build-deb.test.sh`
- Modify: `README.md`

- [ ] Write a fixture test that builds a `.deb` and verifies package name, version, launcher, desktop entry, and app payload.
- [ ] Run it and confirm the builder is missing.
- [ ] Implement safe staging, version validation, `dpkg-deb --build`, and no-install behavior.
- [ ] Document `scripts/build-deb.sh` for approved candidate/runtime directories.
- [ ] Run the package test and `dpkg-deb --info`/contents checks.

### Task 5: Managed Node runtime

**Files:**
- Create: `scripts/managed-node.sh`
- Modify: `port-codex-app-mint.sh`
- Modify: `scripts/install-linux-automation.js`
- Create: `tests/managed-node.test.sh`
- Modify: `README.md`

- [ ] Write tests for architecture mapping, pinned archive URL, checksum lookup, and managed-node preference in generated wrappers.
- [ ] Run them and confirm the helper/preference is missing.
- [ ] Implement download/cache/extract/checksum verification with an overridable base URL for tests.
- [ ] Bundle the runtime into `resources/managed-node` and prefer it for Browser/Computer Use and CLI lookup while retaining safe fallbacks.
- [ ] Run focused tests and an install-script test.

### Task 6: Computer Use capability surface

**Files:**
- Modify: `linux-runtime/linux-computer-use.mjs`
- Modify: `linux-runtime/linux-computer-use.SKILL.md`
- Modify: `tests/computer-use-acceptance.mjs`

- [ ] Write acceptance assertions for `computer_get_capabilities`, X11 control capability, and truthful Wayland limitations.
- [ ] Run them and confirm the tool is missing.
- [ ] Implement capability discovery and optional Wayland screenshot selection (`grim` or `gnome-screenshot`), keeping input tools X11-only.
- [ ] Update the skill documentation and acceptance output.
- [ ] Run Computer Use acceptance and all existing tests.

### Task 7: Full verification and handoff

**Files:**
- Modify: `README.md`
- Modify: `docs/compatibility.md`

- [ ] Run the complete test suite and shell syntax checks.
- [ ] Run a real managed-runtime/package smoke check where dependencies are available.
- [ ] Review `git diff`, generated artifacts, and security-sensitive paths.
- [ ] Commit the implementation on the current Linex branch only after verification.
