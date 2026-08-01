# Safe Desktop Handoff Design

## Goal

Allow a human-approved Linux Mint Codex candidate to replace the current
desktop runtime without requiring the current app to remain open.  The local
handoff must restore the prior release when the replacement fails at startup.

## Scope

This design changes only local release behavior.  It does not expose SSH,
store credentials, redistribute application files, or preserve a ChatGPT
conversation after its desktop app exits.

## Lifecycle

`approve <version>` remains the explicit human-verification gate.  `promote
<version>` records a single, owner-only pending handoff and starts a transient
`systemd --user` unit.  The command returns after the unit is queued; it does
not mutate the active runtime while Codex is open.

The unit waits until the active Codex process is absent, validates the pending
record, approval marker, candidate metadata, and all runtime paths, then
adopts the pre-existing active directory as a versioned release if necessary.
It moves the candidate under `runtime/releases/<version>/codex-app`, switches
the stable `runtime/codex-app` symlink atomically, and launches its `start.sh`.

The unit regards the replacement as healthy only after its Electron process
remains alive for 45 seconds.  An early exit restores the saved release
symlink and launches that release.  If no prior release exists, it records a
failed handoff rather than guessing at a rollback.  Old and new runtimes never
run simultaneously, avoiding their shared localhost webview service.

## State and operations

State lives under the existing generated `runtime/` tree and is mode 0700;
records and result files are mode 0600.  The pending record contains only a
validated version, build, prior-release version, and unit name.  It contains
no archive, runtime, token, account data, or arbitrary command.

The controller adds `handoff-status` and `handoff-cancel`.  Only one handoff
may be pending.  New promotion requests reject duplicate, malformed, stale,
unapproved, mismatched, or symlink-redirected state.  Cancellation is allowed
only before the switch begins.

The service receives the graphical environment from the systemd user manager:
`DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, and
`DBUS_SESSION_BUS_ADDRESS`.  It writes a durable log/result record and sends a
best-effort desktop notification.  Notification failure does not change the
release outcome.

## Validation

Hermetic tests use temporary runtime trees, fake process checks, fake service
submission, and fake launch/notification commands.  They cover deferred
promotion, process exit, launch success, launch failure with rollback,
cancellation, duplicate rejection, invalid state rejection, and diagnostics.
An optional foreground runner mode permits all behavior to be tested without
the real Codex desktop process.  A live handoff is performed only after a
current candidate has passed its existing automated checks and a maintainer
has completed the human approval checklist.
