# Linex Linux Hardening and Packaging Design

**Goal:** Make Linex safer to update, easier to install, and more portable without weakening the existing human approval gate or changing the working Linux Mint X11 Computer Use path.

## Scope

This change implements five approved improvements:

1. Patch the bundled Browser client so Linux Browser Use sockets are scoped to the current user and extension discovery cannot cross socket namespaces.
2. Record upstream archive identity and content fingerprints during builds, and expose structured release metadata for CI.
3. Update the scheduled GitHub verification workflow to detect version/build/fingerprint drift and create one issue per upstream identity.
4. Build a manual Debian package from an already verified runtime; package creation never promotes or installs the app.
5. Bundle a pinned Linux Node runtime for Browser/Computer Use helpers, and add capability-based Computer Use reporting with optional read-only Wayland screenshots. X11 input remains the only write-capable backend in this iteration.

## Architecture

The existing port script remains the orchestration entry point. A new Browser patch runs after the Linux Browser routing patch and before `app.asar` is repacked. The generated browser-client hash remains part of the existing trust boundary; the installer writes that hash into runtime metadata so tests and launchers can use the exact patched client.

Upstream release metadata is produced by a small standalone Python utility. It parses the official Sparkle appcast, optionally performs a HEAD request, and optionally hashes a local archive. The port script writes the same metadata beside `app-version` and `app-build`, allowing local release validation and GitHub Actions to consume one schema.

The Debian builder stages the verified app directory under `/opt/linex-codex`, installs a small `/usr/bin/linex-codex` launcher and a desktop entry, and emits a `.deb` without invoking `sudo`, `pkexec`, or an updater. The package is an artifact for a human to install after approval.

The managed Node helper downloads a pinned official Node Linux tarball, verifies its SHA-256 from the official checksum manifest, and installs only `bin/`, `lib/`, and license files into `resources/managed-node`. The launcher and Browser/Computer Use wrappers prefer that runtime and fall back to the existing primary runtime or system Node.

Computer Use exposes `computer_get_capabilities` on every enabled session. X11 retains full controls. Wayland reports available read-only screenshot backends (`grim` or `gnome-screenshot`) and returns a state snapshot without pretending that pointer or keyboard injection is available. Mutating tools fail with a capability-specific error.

## Safety and compatibility

- Human approval remains required before promotion.
- No cookies, browser profiles, credentials, or personal data are read.
- No package is installed automatically.
- Source archives remain obtained from the official OpenAI CDN or an explicitly supplied local archive.
- The current Mint/X11 acceptance tests remain mandatory.
- Missing optional Wayland tools produce diagnostics, not false success.

## Verification

- Node tests cover Browser patch idempotency, per-user socket behavior, managed-runtime preference, and Computer Use capability responses.
- Shell tests cover source metadata, Debian package contents, and release workflow behavior.
- Existing browser bridge, Linux automation, Computer Use, source-option, release, and handoff tests must continue to pass.
- A fresh candidate build records `source-fingerprint.json` and includes it in the candidate report.
