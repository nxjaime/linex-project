# Linex Update Loop Design

## Purpose

Maintain a privately managed Linux Mint port of the ChatGPT/Codex desktop app
without ever replacing the working runtime until a maintainer has approved a
tested candidate.

The GitHub repository is named **linex-project**. It stores only source,
automation, test code, and compatibility records. It never stores upstream app
archives, extracted application files, generated runtimes, credentials, or
personal data.

## Design

The existing GitHub Action remains the remote detection layer. Every six hours
it reads OpenAI's appcast. A newer upstream version opens one deduplicated
verification issue.

Local commands in this repository manage the live installation at
`/home/nickj/codex-app-mint` by default. They use versioned paths beneath that
installation's `runtime` directory:

```text
runtime/
  candidates/<upstream-version>/codex-app/
  releases/<upstream-version>/codex-app/
  codex-app -> releases/<upstream-version>/codex-app
```

The existing launcher continues to target `runtime/codex-app/start.sh`, so the
promotion operation changes the `codex-app` symlink only after the desktop app
is closed. The previously approved release stays in `releases/` for rollback.

The first promotion performs a one-time adoption: it moves the existing
`runtime/codex-app` directory into `releases/<its-app-version>/codex-app` and
then creates the `codex-app` symlink. Adoption refuses to proceed if the
runtime has no readable version metadata or a release directory of that name
already exists. Later promotions do not move or delete an approved release.

## Commands

`./scripts/linex-release.sh check`

- Reads the appcast and the active runtime metadata.
- Reports the latest upstream version/build, active version/build, and whether
  a candidate already exists.
- Does not download, build, alter the launcher, or change the live runtime.

`./scripts/linex-release.sh build-candidate [version]`

- Resolves the requested version from the official appcast; with no version,
  uses the newest appcast item.
- Invokes the existing port script with a candidate-only output directory and
  `--skip-desktop-entry`.
- Verifies the candidate's `app-version` and `app-build` match the appcast.
- Runs post-build acceptance tests against the candidate runtime.
- Does not create or alter `runtime/codex-app`.

`./scripts/linex-release.sh promote <version>`

- Refuses to run when the live desktop app is running.
- Requires a local approval marker created by `approve <version>` after the
  maintainer has launched and manually verified the candidate.
- Moves the candidate under `releases/<version>/codex-app` and atomically
  replaces the `runtime/codex-app` symlink.
- Retains every existing approved release; it never deletes a release.

`./scripts/linex-release.sh rollback <version>`

- Refuses to run while the live desktop app is running.
- Switches the symlink only to an already approved release.
- Does not download, rebuild, or delete files.

`./scripts/linex-release.sh approve <version>` writes a local marker only. It
does not promote the candidate. This keeps the human decision explicit and
auditable on the machine without placing personal verification data in Git.

## Human Verification Gate

Before `approve`, the maintainer checks the candidate in Linux Mint:

1. It launches from its candidate `start.sh`.
2. Sign-in and existing conversations remain available.
3. A local project opens and a safe read-only task runs.
4. Git/diff and terminal views open.
5. The browser and computer-use smoke tests passed during the candidate build.

The approval marker is required, but not sufficient: `promote` also validates
candidate metadata and refuses to run if the desktop app is open.

## Version Records

An approved release receives two durable records:

1. A compatibility-table entry containing upstream version, internal build,
   verification date, and status.
2. An annotated Git tag named `mint-app-<upstream-version>` pushed to the
   private repository after the compatibility record is committed.

Candidate builds, rejected builds, and approval markers remain local and are
ignored by Git. Only a release that passes human verification gets a Git tag.

## Failure Handling

- Appcast, download, port, or smoke-test failures leave the live symlink
  unchanged.
- A failed candidate can be inspected or rebuilt; no automatic cleanup removes
  it.
- A bad approved release can be rolled back by selecting a prior release.
- A candidate that lacks a matching appcast version/build cannot be approved or
  promoted.

## Testing

Automated tests simulate a live runtime, candidate runtime, appcast, and
process-check command without downloading the proprietary application. They
verify that check is read-only, build targets a candidate directory, promotion
requires approval and switches only after safety checks, and rollback accepts
only an approved release.

The real post-build acceptance tests are executed only after a candidate has
been built on Linux Mint and are given an explicit runtime directory argument.
