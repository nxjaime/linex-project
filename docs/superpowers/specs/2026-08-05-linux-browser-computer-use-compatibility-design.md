# Linux Browser and Computer Use Compatibility Design

## Purpose

Make browser automation and desktop control durable across upstream Codex app
updates on Linux Mint. A candidate must not be promotable when the in-app
browser bridge, external Chrome bridge, or X11 Computer Use behavior is
incompatible with the upstream application bundled in that candidate.

This work extends the existing source-only `linex-project` update loop. It does
not publish upstream application archives, generated runtimes, credentials,
browser profiles, conversation data, or other personal information.

## Scope

The supported interaction surfaces are:

1. The Codex in-app browser.
2. An external Chrome-family browser connected through the ChatGPT browser
   extension.
3. Firefox and other Linux desktop applications through X11 Computer Use.

There is no dedicated Firefox browser connector in the upstream plugin set.
Firefox support therefore means verified screenshot, focus, pointer, click,
keyboard, typing, scrolling, and window-management behavior through Computer
Use. It does not claim Chrome-extension browser APIs for Firefox.

## Compatibility Boundary

Upstream plugin files remain authoritative and are not edited in place in this
repository. Linux-specific behavior is implemented at the port boundary:

- `linux-runtime/node-repl.mjs` supplies the privileged capabilities expected
  by the upstream browser client.
- `linux-runtime/x11-input.py` supplies absolute X11 desktop input.
- `scripts/install-linux-automation.js` installs those adapters into every
  generated candidate.
- Candidate tests inspect the candidate's own bundled browser client and run
  against the candidate runtime, rather than relying on the currently active
  app.

This boundary minimizes version-specific patches. When upstream adds a new
required bridge capability, the candidate test must fail with the missing
capability named before the live runtime can be changed.

## Browser Bridge Compatibility

The Linux Node bridge will implement the lifecycle hook used by current
browser-client builds. The hook registration API will:

- accept upstream hook registrations without weakening browser-client trust
  checks;
- retain registered hooks within the persistent evaluation context;
- execute the hooks after submitted code completes;
- bound hook execution by the requested timeout;
- isolate hook failures from the completed user evaluation while reporting
  useful diagnostics; and
- reset hook state when the persistent session is reset.

The existing SHA-256 allowlist for importing `browser-client.mjs` remains in
force. Adding lifecycle compatibility must not grant an arbitrary imported
module access to the native browser pipe.

An automated contract test will load a minimal trusted browser-client fixture,
register a post-submission hook, execute a second request, and prove that the
hook ran. The existing smoke test will also assert that the lifecycle API is
present in the generated candidate.

## Browser Surface Verification

Candidate verification has two levels:

### Build-time contract tests

- The candidate contains the upstream in-app-browser and Chrome-capable
  browser plugin assets required by its own build.
- The candidate bridge satisfies the browser-client capability contract.
- Browser-client trust hashing still rejects untrusted files.
- Plugin installation does not remove a browser surface required for external
  Chrome discovery.

### Live acceptance tests

- The in-app browser can be selected, documentation can be retrieved, a tab
  can be inspected, and a harmless page operation succeeds.
- When a Chrome extension instance is connected, Chrome can be selected and a
  harmless read-only tab operation succeeds.
- If Chrome is not installed or its extension is not connected, the candidate
  records that condition as `not available` rather than falsely passing it.
  Promotion requires the maintainer to resolve or explicitly record that
  environmental exception.

The tests never inspect cookies, passwords, browser storage, or profile files.

## X11 Coordinate Correctness

Computer Use coordinates are absolute root-window coordinates. The X11 helper
will explicitly declare and verify the C signatures for pointer query and warp
operations, synchronize with the X server after a warp, and report the actual
root coordinates observed after movement.

The acceptance fixture will discover its current client origin immediately
before each window-relative action. This avoids treating stale window geometry
as an input failure when Cinnamon moves or decorates the fixture. The test will
separately verify:

- absolute movement to multiple points across the desktop;
- pointer readback at each requested point;
- click delivery to a fixture button;
- focus and typed text delivery;
- modifier keys and replacement typing;
- scrolling and dragging; and
- behavior on the active multi-monitor geometry.

Assertions remain exact for X11 root coordinates. The test will not introduce
a broad tolerance or silently translate failures because that could make an
unsafe click appear successful.

## Release Gate

`build-candidate` will run, in order:

1. Static and unit tests for the Linux compatibility adapters.
2. Browser bridge contract and trust-boundary tests.
3. Existing Linux automation smoke tests against the candidate runtime.
4. X11 Computer Use acceptance tests against the candidate runtime.
5. A live-browser verification report for in-app Browser and external Chrome.

Any required test failure leaves the candidate under `runtime/candidates/`,
leaves the active symlink unchanged, and prevents approval. Human verification
and the existing protected handoff remain required even when all automated
checks pass.

## Versioning and Durable Records

The compatibility table will distinguish these statuses:

- `Candidate failed`: automated compatibility failed; never promoted.
- `Automated verified`: required candidate tests passed; awaiting a person.
- `Verified locally`: a person approved the candidate and the protected
  handoff remained healthy.

After successful promotion, the repository records the upstream application
version, internal build, verification date, tested browser surfaces, and any
environmental exception. The annotated tag remains
`mint-app-<upstream-version>`.

## Failure and Rollback Behavior

- A missing browser capability fails during candidate testing, before launch.
- A browser connection unavailable because an extension is absent is reported
  distinctly from a compatibility failure.
- X11 coordinate, click, typing, scroll, or drag failures block approval.
- Live-browser acceptance failures block approval.
- The active runtime and launcher are never modified by candidate testing.
- The existing protected handoff retains the prior approved release and rolls
  back if the promoted app does not remain healthy.

## Security and Privacy

- Browser-client native-pipe access remains limited to a trusted file hash.
- Tests use local fixtures or harmless read-only operations.
- Tests do not export screenshots, tabs, browsing data, credentials, or
  personal content to GitHub.
- Generated application code and candidates remain excluded from Git.
- GitHub receives only source adapters, tests, documentation, compatibility
  metadata, and annotated version tags.

