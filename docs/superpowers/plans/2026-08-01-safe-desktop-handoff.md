# Safe Desktop Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` task by task with TDD and fresh verification.

**Goal:** Queue, switch, launch, and—if needed—rollback an approved Linux Mint Codex update without relying on the running desktop app.

**Architecture:** Extend `scripts/linex-release.sh` with a strictly validated pending-handoff record and commands that schedule a transient per-user systemd unit.  Add a small foreground-capable runner responsible for waiting, atomic switching, launching, health checking, rollback, results, and notification.  Existing candidate build and human approval rules stay unchanged.

**Tech Stack:** Bash, systemd user units, existing Node/Bash tests, `notify-send` when available.

## Global constraints

- Never publish or commit archives, generated runtimes, credentials, approval markers, or personal data.
- Keep SSH unchanged; no network service is added.
- A candidate must be approved before it can be queued.
- Never switch while the existing Codex process is running.
- Use 45 seconds as the replacement startup health window.

### Task 1: Define handoff state and controller interface

**Files:** Modify `scripts/linex-release.sh`; modify `tests/linex-release.test.sh`.

- [ ] Write failing tests for `promote` queueing a validated pending record without moving the active runtime, `handoff-status` reporting it, duplicate promotion rejection, and `handoff-cancel` removing it before a switch.
- [ ] Run `bash tests/linex-release.test.sh`; confirm the new assertions fail because the commands and state do not exist.
- [ ] Implement a mode-0700 `runtime/handoffs` root, an atomically written mode-0600 pending record, and `promote`, `handoff-status`, and `handoff-cancel` interfaces.  Provide test-only service-submission command injection.
- [ ] Rerun `bash tests/linex-release.test.sh` and `bash -n scripts/linex-release.sh`; confirm both pass.
- [ ] Commit the controller state/interface change.

### Task 2: Implement the deferred handoff runner

**Files:** Create `scripts/linex-handoff-runner.sh`; modify `scripts/linex-release.sh`; modify `tests/linex-release.test.sh`.

- [ ] Add failing fixture tests for waiting until the process is absent, preserving the old release, promoting and launching the candidate, and automatic rollback/relaunch when the fake candidate exits before 45 seconds.
- [ ] Run the controller test and confirm the new lifecycle assertions fail because the runner does not exist.
- [ ] Implement the runner with validated record loading, process polling, atomic release switching, injected launch/health commands for tests, best-effort notification, and terminal result records.  Permit a foreground mode used only by tests.
- [ ] Rerun the controller test and shell syntax checks; confirm all pass.
- [ ] Commit the runner and lifecycle behavior.

### Task 3: Submit and diagnose user services

**Files:** Modify `scripts/linex-release.sh`; modify `tests/linex-release.test.sh`; modify `README.md`.

- [ ] Add failing tests that assert the generated `systemd-run --user --collect` invocation has a unique safe unit name and passes only the captured graphical environment plus validated runner arguments.
- [ ] Run the controller test and confirm failure before implementation.
- [ ] Implement transient unit submission, service-unit recording, and status output that includes pending/running/result state.  Keep no credentials in systemd arguments or state.
- [ ] Document status, cancellation, logs, notifications, automatic rollback, and the human reconnect step.
- [ ] Rerun all hermetic tests, shell syntax checks, and source-option/runtime-interface tests; confirm all pass.
- [ ] Commit code, tests, and documentation.

### Task 4: Integrate and validate safely

**Files:** Modify `docs/compatibility.md` only if a live handoff is actually verified.

- [ ] Rebase the feature branch on the published appcast-monitor fix and resolve only intentional conflicts.
- [ ] Run the complete source-only test suite in the feature worktree.
- [ ] Validate the transient user-service plumbing with a fake runtime and foreground runner; do not close or alter the live Codex app.
- [ ] Build a fresh upstream candidate, complete the existing human checks, then queue one deliberate live handoff.  Record compatibility/tag only after the human confirms the replacement is working.
