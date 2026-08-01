# Linex Update Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and operate Linux Mint desktop-app candidates safely, with explicit human approval, rollback, and durable version records.

**Architecture:** `scripts/linex-release.sh` is the local release controller. It reads the official appcast, directs the existing port script to a candidate-only location, runs acceptance tests against that explicit candidate, and changes the live `runtime/codex-app` path only by switching an approved-release symlink. The GitHub Action remains detection-only; Git records only source, documentation, compatibility results, and annotated approval tags.

**Tech Stack:** Bash, Python 3 standard library XML parsing, Node.js acceptance tests, GitHub Actions, Git tags.

## Global Constraints

- The GitHub repository is private and named `nxjaime/linex-project`.
- Never commit upstream archives, generated runtimes, credentials, approval markers, or personal data.
- The default live installation is `/home/nickj/codex-app-mint`; provide `LINEX_INSTALL_ROOT` for a different installation.
- Candidate builds must never overwrite `runtime/codex-app` or the desktop-entry file.
- `approve` records a human decision locally; only `promote` changes the live launcher path.
- `promote` and `rollback` must refuse while the desktop app is running.
- An approved build receives a compatibility-table record and an annotated tag `mint-app-<version>`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/linex-release.sh` | Read appcast, build/test candidate, record approval, adopt/promote/rollback releases. |
| `tests/linex-release.test.sh` | Hermetic controller tests using a local appcast, fake port command, and temporary runtime tree. |
| `tests/linux-automation-smoke.mjs` | Accept a runtime path through `CODEX_APP_RUNTIME_DIR`. |
| `tests/computer-use-acceptance.mjs` | Accept a runtime path through `CODEX_APP_RUNTIME_DIR`. |
| `port-codex-app-mint.sh` | Accept a `.zip` archive from the official appcast as well as the existing DMG source. |
| `README.md` | Describe the candidate/approval/promotion workflow and rollback. |
| `docs/compatibility.md` | Define exact recording and tagging procedure for approved builds. |
| `.gitignore` | Ignore local candidate/release state produced when the lab itself is the install root. |

## Task 1: Allow porting from an appcast archive without changing the live launcher

**Files:**
- Modify: `port-codex-app-mint.sh:17-72, 114-178, 505-540`
- Create: `tests/port-source-options.test.sh`
- Modify: `README.md:24-76`

**Interfaces:**
- Consumes: `CODEX_PORT_SOURCE_URL`, `CODEX_PORT_SOURCE_ARCHIVE`, and `--archive PATH`.
- Produces: `extract_app_bundle`, which prints the extracted `.app` directory for either DMG or ZIP input.
- Preserves: `--dmg PATH` as a documented compatibility alias.

- [ ] **Step 1: Write the failing source-option test**

Create `tests/port-source-options.test.sh` with a temporary shell fixture that runs the port script’s source parser through a `--help`-free test hook. Require these assertions:

```bash
assert_contains "$output" 'CODEX_PORT_SOURCE_URL'
assert_contains "$output" '--archive PATH'
assert_contains "$output" '--dmg PATH'
```

Run: `bash tests/port-source-options.test.sh`

Expected: FAIL because the generic archive option and environment variable do not exist.

- [ ] **Step 2: Add generic source variables and argument parsing**

Replace the DMG-only variables with the following names while retaining the default DMG URL:

```bash
DEFAULT_SOURCE_PATH="$CACHE_DIR/Codex.dmg"
SOURCE_ARCHIVE=""
SOURCE_URL="${CODEX_PORT_SOURCE_URL:-${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}}"
```

Add `--archive PATH`, make `--dmg PATH` assign the same `SOURCE_ARCHIVE`, and document both source URL names. Do not remove `CODEX_DMG_URL`.

- [ ] **Step 3: Generalize source download and extraction**

Replace `resolve_dmg_path` and `extract_dmg` with `resolve_source_archive` and `extract_app_bundle`:

```bash
case "$SOURCE_ARCHIVE" in
  *.zip) unzip -q "$SOURCE_ARCHIVE" -d "$extract_dir" ;;
  *.dmg) "$SEVEN_ZIP_CMD" x -y -snl "$SOURCE_ARCHIVE" -o"$extract_dir" >"$seven_zip_log" 2>&1 ;;
  *) error "Unsupported upstream archive: $SOURCE_ARCHIVE" ;;
esac
app_dir="$(find "$extract_dir" -maxdepth 5 -name '*.app' -type d | head -n 1 || true)"
[ -n "$app_dir" ] || error "Could not find a .app bundle after extracting the upstream archive"
```

For a downloaded URL, select the cache filename from its path suffix (`.zip` or `.dmg`) and reject all other suffixes before downloading. Continue to use 7-zip only for DMG files.

- [ ] **Step 4: Verify source option test passes and shell syntax is valid**

Run:

```bash
bash tests/port-source-options.test.sh
bash -n port-codex-app-mint.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Document generic archive usage**

Add this README example after the DMG example:

```bash
CODEX_PORT_SOURCE_URL='https://persistent.oaistatic.com/.../ChatGPT-darwin-arm64-<version>.zip' \
  bash ./port-codex-app-mint.sh --skip-desktop-entry
```

State that only an official appcast enclosure URL should be used.

- [ ] **Step 6: Commit**

```bash
git add port-codex-app-mint.sh tests/port-source-options.test.sh README.md
git commit -m "feat: support appcast archives for Mint candidates"
```

## Task 2: Make post-build acceptance tests target a candidate explicitly

**Files:**
- Modify: `tests/linux-automation-smoke.mjs:6-8`
- Modify: `tests/computer-use-acceptance.mjs:8-18`
- Create: `tests/runtime-path-options.test.mjs`

**Interfaces:**
- Consumes: `CODEX_APP_RUNTIME_DIR`, an absolute path to a generated `codex-app` runtime.
- Produces: both acceptance scripts use that directory; without it they retain the current `runtime/codex-app` default.

- [ ] **Step 1: Write the failing runtime-path test**

Create `tests/runtime-path-options.test.mjs` that reads each test file and asserts this executable interface is present:

```js
const runtimeDir = process.env.CODEX_APP_RUNTIME_DIR
  ? path.resolve(process.env.CODEX_APP_RUNTIME_DIR)
  : path.join(projectDir, "runtime", "codex-app");
```

Run: `node tests/runtime-path-options.test.mjs`

Expected: FAIL because both files hard-code `runtime/codex-app`.

- [ ] **Step 2: Add the runtime-path interface**

Replace each hard-coded runtime construction with the snippet above. In `computer-use-acceptance.mjs`, derive `serverPath` from the new `runtimeDir`.

- [ ] **Step 3: Verify the interface and syntax**

Run:

```bash
node tests/runtime-path-options.test.mjs
node --check tests/linux-automation-smoke.mjs
node --check tests/computer-use-acceptance.mjs
```

Expected: all commands exit 0. Do not run the real acceptance scripts until a generated candidate exists.

- [ ] **Step 4: Commit**

```bash
git add tests/linux-automation-smoke.mjs tests/computer-use-acceptance.mjs tests/runtime-path-options.test.mjs
git commit -m "test: target acceptance checks at candidate runtimes"
```

## Task 3: Add the guarded local release controller

**Files:**
- Create: `scripts/linex-release.sh`
- Create: `tests/linex-release.test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes commands: `check`, `build-candidate [version]`, `approve <version>`, `promote <version>`, and `rollback <version>`.
- Consumes environment: `LINEX_INSTALL_ROOT`, `LINEX_APPCAST_URL`, `LINEX_PORT_COMMAND`, `LINEX_SMOKE_TEST_COMMAND`, `LINEX_ACCEPTANCE_TEST_COMMAND`, and `LINEX_PROCESS_CHECK_COMMAND` for isolated testing.
- Produces state: `<install-root>/runtime/candidates/<version>/codex-app`, `<install-root>/runtime/releases/<version>/codex-app`, and `<install-root>/runtime/approvals/<version>.approved`.

- [ ] **Step 1: Write failing controller tests**

Create `tests/linex-release.test.sh`. Use `mktemp -d`, a file:// appcast fixture, and fake port/test commands. Cover these exact cases:

```bash
run check
assert_contains "$output" 'Latest upstream: 26.721.81911 (build 5973)'
assert_path_is_dir "$live_root/runtime/codex-app"

run build-candidate 26.721.81911
assert_path_is_dir "$live_root/runtime/candidates/26.721.81911/codex-app"
assert_path_is_dir "$live_root/runtime/codex-app"

run_expect_failure promote 26.721.81911
assert_contains "$output" 'Approve the candidate first'

run approve 26.721.81911
run promote 26.721.81911
assert_path_is_symlink "$live_root/runtime/codex-app"
assert_link_target "$live_root/runtime/codex-app" "$live_root/runtime/releases/26.721.81911/codex-app"

run rollback 26.721.41059
assert_link_target "$live_root/runtime/codex-app" "$live_root/runtime/releases/26.721.41059/codex-app"
```

Also cover a running-process check that causes both `promote` and `rollback` to fail without changing the symlink. Run: `bash tests/linex-release.test.sh`. Expected: FAIL because the controller does not exist.

- [ ] **Step 2: Implement appcast parsing and read-only check**

In `scripts/linex-release.sh`, set:

```bash
INSTALL_ROOT="${LINEX_INSTALL_ROOT:-/home/nickj/codex-app-mint}"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
APPCAST_URL="${LINEX_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast.xml}"
```

Use Python standard-library XML parsing to print tab-separated `version`, `build`, and `url` for the requested appcast item. `check` must print active and newest metadata and must make no filesystem changes.

- [ ] **Step 3: Implement candidate build and metadata checks**

`build-candidate` must resolve the requested appcast item, reject an unknown version, and execute:

```bash
CODEX_PORT_OUTPUT_ROOT="$candidate_root" \
CODEX_PORT_INSTALL_DIR="$candidate_dir" \
CODEX_PORT_CACHE_DIR="$RUNTIME_ROOT/cache" \
CODEX_PORT_SOURCE_URL="$archive_url" \
"$PORT_COMMAND" --fresh --skip-desktop-entry
```

Then require exact matches in `app-version` and `app-build`, and run both commands with `CODEX_APP_RUNTIME_DIR="$candidate_dir"`. The default commands are:

```bash
node "$LAB_ROOT/tests/linux-automation-smoke.mjs"
node "$LAB_ROOT/tests/computer-use-acceptance.mjs"
```

No code path in this command may edit or remove `runtime/codex-app`.

- [ ] **Step 4: Implement approval, adoption, promotion, and rollback**

Create `runtime/approvals` with mode 0700. `approve` must require matching candidate metadata, then use `umask 077` and write the approved version/build/date to `<version>.approved`.

Implement `ensure_not_running` by executing `${LINEX_PROCESS_CHECK_COMMAND:-pgrep -f "$RUNTIME_ROOT/codex-app/(electron|start.sh)"}` and treating exit code 0 as running, exit code 1 as not running, and any other result as an error.

During first promotion, if `runtime/codex-app` is a directory, read its version, move it to `releases/<version>/codex-app`, then replace its path using a temporary symlink plus `mv -T`:

```bash
ln -s "releases/$version/codex-app" "$RUNTIME_ROOT/.codex-app.next"
mv -Tf "$RUNTIME_ROOT/.codex-app.next" "$RUNTIME_ROOT/codex-app"
```

For later promotion, move the approved candidate to its release directory, then perform the same symlink switch. Reject a pre-existing target release or a missing approval marker. `rollback` accepts only a release directory with `app-version` equal to the requested version.

- [ ] **Step 5: Run the controller tests and shell validation**

Run:

```bash
bash tests/linex-release.test.sh
bash -n scripts/linex-release.sh
```

Expected: both commands exit 0.

- [ ] **Step 6: Ignore only generated local controller state**

Add these entries to `.gitignore`:

```gitignore
runtime/candidates/
runtime/releases/
runtime/approvals/
```

Do not ignore scripts, tests, documentation, or `.github/`.

- [ ] **Step 7: Commit**

```bash
git add scripts/linex-release.sh tests/linex-release.test.sh .gitignore
git commit -m "feat: add guarded Linex release controller"
```

## Task 4: Document manual verification, recording, and tags

**Files:**
- Modify: `README.md:47-76, 118-134`
- Modify: `docs/compatibility.md:7-15`

**Interfaces:**
- Consumes: an approved local candidate version and app build.
- Produces: a compatibility row and an annotated tag `mint-app-<version>` only after human verification.

- [ ] **Step 1: Write the documentation assertion**

Extend `tests/linex-release.test.sh` with:

```bash
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh build-candidate'
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh approve'
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh promote'
assert_file_contains "$LAB_ROOT/docs/compatibility.md" 'mint-app-<upstream-version>'
```

Run: `bash tests/linex-release.test.sh`. Expected: FAIL until the documentation is updated.

- [ ] **Step 2: Update README workflow**

Replace the immediate updater example with these commands:

```bash
./scripts/linex-release.sh check
./scripts/linex-release.sh build-candidate 26.721.81911
# Launch the candidate and perform the listed human checks.
./scripts/linex-release.sh approve 26.721.81911
./scripts/linex-release.sh promote 26.721.81911
./scripts/linex-release.sh rollback 26.721.41059
```

Include the five-item human verification checklist from the design and clearly state that `promote` changes the live installation while `approve` does not.

- [ ] **Step 3: Update compatibility recording procedure**

Add this exact post-promotion sequence:

```bash
# Replace fields with the approved app metadata and date.
git add docs/compatibility.md
git commit -m "docs: verify Mint app <upstream-version>"
git tag -a "mint-app-<upstream-version>" -m "Verified on Linux Mint: build <build>"
git push origin main --follow-tags
```

State that the GitHub verification issue may be closed only after this commit and tag are pushed.

- [ ] **Step 4: Verify documentation assertion and repository validation**

Run:

```bash
bash tests/linex-release.test.sh
bash -n port-codex-app-mint.sh scripts/linex-release.sh
node tests/runtime-path-options.test.mjs
python3 - <<'PY'
from pathlib import Path
assert 'runtime/' in Path('.gitignore').read_text()
PY
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/compatibility.md tests/linex-release.test.sh
git commit -m "docs: document Linex approval and versioning loop"
```

## Task 5: Verify the repository and perform the first candidate run

**Files:**
- Modify: `docs/compatibility.md` only if 26.721.81911 passes human verification.

**Interfaces:**
- Consumes: the completed controller and official appcast candidate `26.721.81911` / build `5973`.
- Produces: a local candidate, then only after human verification an approved release and Git version record.

- [ ] **Step 1: Run source-only checks**

Run:

```bash
git status --short
bash tests/port-source-options.test.sh
bash tests/linex-release.test.sh
node tests/runtime-path-options.test.mjs
bash -n port-codex-app-mint.sh scripts/linex-release.sh
```

Expected: no uncommitted generated runtime files and every automated source test passes.

- [ ] **Step 2: Create the real candidate without touching the live app**

Run:

```bash
./scripts/linex-release.sh check
./scripts/linex-release.sh build-candidate 26.721.81911
```

Expected: `runtime/candidates/26.721.81911/codex-app` exists under `/home/nickj/codex-app-mint`, acceptance tests pass, and the live `runtime/codex-app/app-version` remains `26.721.41059`.

- [ ] **Step 3: Perform human desktop verification**

Launch the candidate’s `start.sh` directly. Confirm launch/sign-in, local project, safe read-only task, Git/diff/terminal views, and the completed smoke tests. Stop if any check fails; do not approve or promote.

- [ ] **Step 4: Approve and promote only after verification**

Run:

```bash
./scripts/linex-release.sh approve 26.721.81911
./scripts/linex-release.sh promote 26.721.81911
./scripts/linex-release.sh check
```

Expected: the live `runtime/codex-app` becomes a symlink to `releases/26.721.81911/codex-app`; the old build remains available under `releases/26.721.41059/codex-app`.

- [ ] **Step 5: Record and tag the verified version**

Add the 26.721.81911 / 5973 compatibility row, commit it, create the annotated `mint-app-26.721.81911` tag, push the feature branch, merge to main after review, push main and the tag, then close the verification issue.

---

## Plan Self-Review

- Spec coverage: candidate isolation, human approval, atomic promotion, first-run adoption, rollback, tests, GitHub detection, repository naming, documentation, and tagging each have a task.
- Placeholder scan: no unresolved TODO/TBD or unspecified implementation steps remain.
- Interface consistency: the controller’s `CODEX_APP_RUNTIME_DIR` contract is established before candidate build execution; paths and command names match the design.
