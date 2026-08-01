#!/usr/bin/env bash
set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROLLER="$LAB_ROOT/scripts/linex-release.sh"
TEST_ROOT="$(mktemp -d)"
LIVE_ROOT="$TEST_ROOT/live+[install]"
APPCAST="$TEST_ROOT/appcast.xml"
APPCAST_HEADER_SERVER="$TEST_ROOT/appcast header server.py"
APPCAST_HEADER_LOG="$TEST_ROOT/appcast header.log"
APPCAST_HEADER_PORT="$TEST_ROOT/appcast header.port"
APPCAST_HEADER_PID=""
FAKE_PORT="$TEST_ROOT/fake port.sh"
FAILING_PORT="$TEST_ROOT/failing port.sh"
FAKE_SMOKE="$TEST_ROOT/fake smoke.sh"
FAKE_ACCEPTANCE="$TEST_ROOT/fake acceptance.sh"
NOT_RUNNING="$TEST_ROOT/not running.sh"
RUNNING="$TEST_ROOT/running process.sh"
PROCESS_ERROR="$TEST_ROOT/process error.sh"
FAKE_HANDOFF_SUBMIT="$TEST_ROOT/fake handoff submit.sh"
FAKE_BIN="$TEST_ROOT/fake bin"
output=""

cleanup() {
  if [ -n "$APPCAST_HEADER_PID" ]; then
    kill "$APPCAST_HEADER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local expected="$2"

  case "$text" in
    *"$expected"*) ;;
    *) fail "expected output to contain '$expected', got: $text" ;;
  esac
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "$expected" "$path" \
    || fail "expected $path to contain '$expected'"
}

assert_path_is_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || fail "expected directory: $1"
}

assert_path_is_symlink() {
  [ -L "$1" ] || fail "expected symlink: $1"
}

assert_path_does_not_exist() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path not to exist: $1"
}

assert_link_target() {
  local link_path="$1"
  local expected="$2"
  local actual=""

  actual="$(readlink -f "$link_path")"
  [ "$actual" = "$expected" ] || fail "expected $link_path to resolve to $expected, got $actual"
}

run() {
  if ! output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command failed: $*"$'\n'"$output"
  fi
}

run_with_process_check() {
  local process_check="$1"
  shift

  if ! output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$process_check" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command failed: $*"$'\n'"$output"
  fi
}

run_expect_failure() {
  if output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

run_expect_failure_with_process_check() {
  local process_check="$1"
  shift

  if output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$process_check" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

run_expect_failure_with_port() {
  local port_command="$1"
  shift

  if output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$port_command" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

run_expect_failure_for_root() {
  local install_root="$1"
  shift

  if output="$(
    LINEX_INSTALL_ROOT="$install_root" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_HANDOFF_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "command unexpectedly succeeded for $install_root: $*"
  fi
}

run_approve_with_legacy_marker() {
  local install_root="$1"
  local version="$2"
  local sentinel="$3"

  if ! output="$(
    LINEX_INSTALL_ROOT="$install_root" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
      bash -c '
        controller="$1"
        command_name="$2"
        version="$3"
        sentinel="$4"
        legacy_marker="$LINEX_INSTALL_ROOT/runtime/approvals/.$version.approved.$$"
        ln -s "$sentinel" "$legacy_marker"
        set -- "$command_name" "$version"
        source "$controller"
      ' bash "$CONTROLLER" approve "$version" "$sentinel" 2>&1
  )"; then
    fail "command failed: approve $version"$'\n'"$output"
  fi
}

make_candidate() {
  local install_root="$1"
  local version="${2:-26.721.81911}"
  local build="${3:-5973}"
  local candidate_dir="$install_root/runtime/candidates/$version/codex-app"

  mkdir -p "$candidate_dir"
  printf '%s\n' "$version" > "$candidate_dir/app-version"
  printf '%s\n' "$build" > "$candidate_dir/app-build"
  printf '%s\n' 'focused-candidate' > "$candidate_dir/candidate-sentinel"
}

make_approval() {
  local install_root="$1"
  local version="${2:-26.721.81911}"
  local build="${3:-5973}"
  local approvals_root="$install_root/runtime/approvals"

  mkdir -p "$approvals_root"
  chmod 0700 "$approvals_root"
  {
    printf 'version=%s\n' "$version"
    printf 'build=%s\n' "$build"
    printf 'approved_at=2026-07-29T00:00:00Z\n'
  } > "$approvals_root/$version.approved"
  chmod 0600 "$approvals_root/$version.approved"
}

mkdir -p "$LIVE_ROOT/runtime/codex-app"
mkdir -p "$FAKE_BIN"
printf '%s\n' '26.721.41059' > "$LIVE_ROOT/runtime/codex-app/app-version"
printf '%s\n' '5555' > "$LIVE_ROOT/runtime/codex-app/app-build"
printf '%s\n' 'working-live-runtime' > "$LIVE_ROOT/runtime/codex-app/live-sentinel"

cat > "$APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:shortVersionString>26.721.81911</sparkle:shortVersionString>
      <sparkle:version>5973</sparkle:version>
      <enclosure url="https://example.invalid/Codex-26.721.81911.zip" />
    </item>
    <item>
      <sparkle:shortVersionString>26.721.70000</sparkle:shortVersionString>
      <sparkle:version>5900</sparkle:version>
      <enclosure url="https://example.invalid/Codex-26.721.70000.zip" />
    </item>
  </channel>
</rss>
XML

cat > "$APPCAST_HEADER_SERVER" <<'PY'
import http.server
import pathlib
import sys

header_log = pathlib.Path(sys.argv[1])
appcast = pathlib.Path(sys.argv[2]).read_bytes()


class AppcastHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        header_log.write_text(self.headers.get("User-Agent", ""))
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(appcast)))
        self.end_headers()
        self.wfile.write(appcast)

    def log_message(self, format, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), AppcastHandler)
print(server.server_address[1], flush=True)
server.handle_request()
PY

cat > "$FAKE_PORT" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 2 ] || exit 20
[ "$1" = "--fresh" ] || exit 21
[ "$2" = "--skip-desktop-entry" ] || exit 22
[ "$CODEX_PORT_OUTPUT_ROOT/codex-app" = "$CODEX_PORT_INSTALL_DIR" ] || exit 23
case "$CODEX_PORT_INSTALL_DIR" in
  */runtime/candidates/*/codex-app) ;;
  *) exit 24 ;;
esac

case "$CODEX_PORT_SOURCE_URL" in
  *Codex-26.721.81911.zip)
    version='26.721.81911'
    build='5973'
    ;;
  *Codex-26.721.70000.zip)
    version='26.721.70000'
    build='5900'
    ;;
  *)
    exit 25
    ;;
esac

rm -rf "$CODEX_PORT_INSTALL_DIR"
mkdir -p "$CODEX_PORT_INSTALL_DIR" "$CODEX_PORT_CACHE_DIR"
printf '%s\n' 'cache-root-write' > "$CODEX_PORT_CACHE_DIR/live-sentinel"
printf '%s\n' "$version" > "$CODEX_PORT_INSTALL_DIR/app-version"
printf '%s\n' "$build" > "$CODEX_PORT_INSTALL_DIR/app-build"
printf '%s\n' 'candidate-runtime' > "$CODEX_PORT_INSTALL_DIR/candidate-sentinel"
SH

cat > "$FAKE_SMOKE" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$CODEX_APP_RUNTIME_DIR" in
  */runtime/candidates/*/codex-app) ;;
  *) exit 30 ;;
esac
[ -f "$CODEX_APP_RUNTIME_DIR/candidate-sentinel" ]
printf '%s\n' 'smoke-passed' > "$CODEX_APP_RUNTIME_DIR/smoke-result"
SH

cat > "$FAILING_PORT" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

version="$(basename "$CODEX_PORT_OUTPUT_ROOT")"
runtime_root="$(dirname "$(dirname "$CODEX_PORT_OUTPUT_ROOT")")"
[ ! -e "$runtime_root/approvals/$version.approved" ] || exit 56
exit 55
SH

cat > "$FAKE_ACCEPTANCE" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$CODEX_APP_RUNTIME_DIR" in
  */runtime/candidates/*/codex-app) ;;
  *) exit 40 ;;
esac
[ -f "$CODEX_APP_RUNTIME_DIR/smoke-result" ]
printf '%s\n' 'acceptance-passed' > "$CODEX_APP_RUNTIME_DIR/acceptance-result"
SH

cat > "$NOT_RUNNING" <<'SH'
#!/usr/bin/env bash
exit 1
SH

cat > "$RUNNING" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$PROCESS_ERROR" <<'SH'
#!/usr/bin/env bash
exit 7
SH

cat > "$FAKE_HANDOFF_SUBMIT" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/pgrep" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 2 ] || exit 8
[ "$1" = '-f' ] || exit 9
[[ "$EXPECTED_PROCESS_COMMAND" =~ $2 ]]
SH

chmod +x "$FAKE_PORT" "$FAILING_PORT" "$FAKE_SMOKE" "$FAKE_ACCEPTANCE" \
  "$NOT_RUNNING" "$RUNNING" "$PROCESS_ERROR" "$FAKE_HANDOFF_SUBMIT" "$FAKE_BIN/pgrep"

python3 "$APPCAST_HEADER_SERVER" "$APPCAST_HEADER_LOG" "$APPCAST" > "$APPCAST_HEADER_PORT" &
APPCAST_HEADER_PID=$!
for _ in {1..100}; do
  [ -s "$APPCAST_HEADER_PORT" ] && break
  sleep 0.01
done
[ -s "$APPCAST_HEADER_PORT" ] || fail 'appcast header fixture did not start'

if ! output="$(
  LINEX_INSTALL_ROOT="$LIVE_ROOT" \
  LINEX_APPCAST_URL="http://127.0.0.1:$(cat "$APPCAST_HEADER_PORT")/appcast.xml" \
  LINEX_PORT_COMMAND="$FAKE_PORT" \
  LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
  LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
  LINEX_PROCESS_CHECK_COMMAND="$NOT_RUNNING" \
    "$CONTROLLER" check 2>&1
)"; then
  fail "command failed: check against appcast header fixture"$'\n'"$output"
fi
wait "$APPCAST_HEADER_PID"
APPCAST_HEADER_PID=""
[ "$(cat "$APPCAST_HEADER_LOG")" = 'Linex/1.0 (+https://github.com/nxjaime/linex-project)' ] \
  || fail 'read_appcast_item did not send the Linex appcast User-Agent'

state_before_check="$(find "$LIVE_ROOT" -printf '%P|%y|%l\n' | sort)"
run check
assert_contains "$output" 'Latest upstream: 26.721.81911 (build 5973)'
assert_contains "$output" 'Active runtime: 26.721.41059 (build 5555)'
assert_path_is_dir "$LIVE_ROOT/runtime/codex-app"
state_after_check="$(find "$LIVE_ROOT" -printf '%P|%y|%l\n' | sort)"
[ "$state_after_check" = "$state_before_check" ] || fail 'check changed the installation tree'

run_expect_failure build-candidate 99.99.99
assert_contains "$output" 'Unknown appcast version: 99.99.99'
assert_path_does_not_exist "$LIVE_ROOT/runtime/candidates/99.99.99"

mkdir -p "$LIVE_ROOT/runtime/candidates"
ln -s .. "$LIVE_ROOT/runtime/candidates/26.721.81911"
run_expect_failure build-candidate 26.721.81911
assert_contains "$output" 'Unsafe candidate path'
assert_path_is_dir "$LIVE_ROOT/runtime/codex-app"
[ "$(cat "$LIVE_ROOT/runtime/codex-app/live-sentinel")" = 'working-live-runtime' ] \
  || fail 'symlinked candidate path changed the live runtime'
rm "$LIVE_ROOT/runtime/candidates/26.721.81911"

ln -s codex-app "$LIVE_ROOT/runtime/cache"
run_expect_failure build-candidate 26.721.81911
assert_contains "$output" 'Unsafe cache path'
assert_path_is_dir "$LIVE_ROOT/runtime/codex-app"
[ "$(cat "$LIVE_ROOT/runtime/codex-app/live-sentinel")" = 'working-live-runtime' ] \
  || fail 'symlinked cache path changed the live runtime'
rm "$LIVE_ROOT/runtime/cache"

run build-candidate 26.721.81911
assert_path_is_dir "$LIVE_ROOT/runtime/candidates/26.721.81911/codex-app"
assert_path_is_dir "$LIVE_ROOT/runtime/codex-app"
[ "$(cat "$LIVE_ROOT/runtime/codex-app/live-sentinel")" = 'working-live-runtime' ] \
  || fail 'candidate build changed the live runtime'
[ -f "$LIVE_ROOT/runtime/candidates/26.721.81911/codex-app/smoke-result" ] \
  || fail 'smoke command did not target the candidate'
[ -f "$LIVE_ROOT/runtime/candidates/26.721.81911/codex-app/acceptance-result" ] \
  || fail 'acceptance command did not target the candidate'

run_expect_failure promote 26.721.81911
assert_contains "$output" 'Approve the candidate first'
assert_path_is_dir "$LIVE_ROOT/runtime/codex-app"

run approve 26.721.81911
[ "$(stat -c '%a' "$LIVE_ROOT/runtime/approvals")" = '700' ] \
  || fail 'approval directory is not mode 0700'
[ "$(stat -c '%a' "$LIVE_ROOT/runtime/approvals/26.721.81911.approved")" = '600' ] \
  || fail 'approval marker is not mode 0600'
grep -Fxq 'version=26.721.81911' "$LIVE_ROOT/runtime/approvals/26.721.81911.approved" \
  || fail 'approval marker lacks version'
grep -Fxq 'build=5973' "$LIVE_ROOT/runtime/approvals/26.721.81911.approved" \
  || fail 'approval marker lacks build'
grep -Eq '^approved_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  "$LIVE_ROOT/runtime/approvals/26.721.81911.approved" \
  || fail 'approval marker lacks UTC approval date'

run_expect_failure_with_port "$FAILING_PORT" build-candidate 26.721.81911
assert_path_does_not_exist "$LIVE_ROOT/runtime/approvals/26.721.81911.approved"
run_expect_failure promote 26.721.81911
assert_contains "$output" 'Approve the candidate first'
run approve 26.721.81911

run promote 26.721.81911
run _complete-handoff 26.721.81911 5973
run handoff-cancel
assert_path_is_symlink "$LIVE_ROOT/runtime/codex-app"
assert_link_target \
  "$LIVE_ROOT/runtime/codex-app" \
  "$LIVE_ROOT/runtime/releases/26.721.81911/codex-app"
assert_path_is_dir "$LIVE_ROOT/runtime/releases/26.721.41059/codex-app"
[ -f "$LIVE_ROOT/runtime/releases/26.721.41059/codex-app/live-sentinel" ] \
  || fail 'first promotion did not preserve the adopted live runtime'

run rollback 26.721.41059
assert_link_target \
  "$LIVE_ROOT/runtime/codex-app" \
  "$LIVE_ROOT/runtime/releases/26.721.41059/codex-app"
assert_path_is_dir "$LIVE_ROOT/runtime/releases/26.721.81911/codex-app"

run build-candidate 26.721.70000
run approve 26.721.70000
safe_target="$(readlink -f "$LIVE_ROOT/runtime/codex-app")"

run_with_process_check "$RUNNING" promote 26.721.70000
assert_contains "$output" 'Queued handoff: 26.721.70000'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'running-process promotion changed the live symlink'
assert_path_is_dir "$LIVE_ROOT/runtime/candidates/26.721.70000/codex-app"
run handoff-cancel

run_expect_failure_with_process_check "$RUNNING" rollback 26.721.81911
assert_contains "$output" 'desktop app is running'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'running-process rollback changed the live symlink'

run_expect_failure_with_process_check "$PROCESS_ERROR" rollback 26.721.81911
assert_contains "$output" 'process check failed with exit code 7'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'failed process check changed the live symlink'

if output="$(
  env -u LINEX_PROCESS_CHECK_COMMAND \
    PATH="$FAKE_BIN:$PATH" \
    EXPECTED_PROCESS_COMMAND="$LIVE_ROOT/runtime/codex-app/electron" \
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
      "$CONTROLLER" rollback 26.721.81911 2>&1
)"; then
  fail 'default running-process check unexpectedly allowed rollback'
fi
assert_contains "$output" 'desktop app is running'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'default running-process check changed the live symlink'

printf '%s\n' 'tampered-build' > "$LIVE_ROOT/runtime/candidates/26.721.70000/codex-app/app-build"
run_expect_failure promote 26.721.70000
assert_contains "$output" 'Candidate build mismatch'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'metadata mismatch changed the live symlink'

printf '%s\n' '5900' > "$LIVE_ROOT/runtime/candidates/26.721.70000/codex-app/app-build"
mkdir -p "$LIVE_ROOT/runtime/releases/26.721.70000"
run_expect_failure promote 26.721.70000
assert_contains "$output" 'Release already exists: 26.721.70000'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'pre-existing release target changed the live symlink'
assert_path_is_dir "$LIVE_ROOT/runtime/candidates/26.721.70000/codex-app"

mkdir -p "$LIVE_ROOT/runtime/releases/26.721.12345/codex-app"
printf '%s\n' 'wrong-version' > "$LIVE_ROOT/runtime/releases/26.721.12345/codex-app/app-version"
run_expect_failure rollback 26.721.12345
assert_contains "$output" 'Release version mismatch'
[ "$(readlink -f "$LIVE_ROOT/runtime/codex-app")" = "$safe_target" ] \
  || fail 'invalid rollback target changed the live symlink'

case_root="$(mktemp -d "$TEST_ROOT/candidate-approve.XXXXXX")"
mkdir -p "$case_root/runtime/candidates" "$case_root/redirected-version"
ln -s "$case_root/redirected-version" \
  "$case_root/runtime/candidates/26.721.81911"
mkdir -p "$case_root/redirected-version/codex-app"
printf '%s\n' '26.721.81911' > "$case_root/redirected-version/codex-app/app-version"
printf '%s\n' '5973' > "$case_root/redirected-version/codex-app/app-build"
run_expect_failure_for_root "$case_root" approve 26.721.81911
assert_contains "$output" 'Unsafe candidate path'
assert_path_does_not_exist "$case_root/runtime/approvals/26.721.81911.approved"

case_root="$(mktemp -d "$TEST_ROOT/candidate-promote.XXXXXX")"
mkdir -p "$case_root/runtime" "$case_root/redirected-candidates"
ln -s "$case_root/redirected-candidates" "$case_root/runtime/candidates"
make_candidate "$case_root"
make_approval "$case_root"
run_expect_failure_for_root "$case_root" promote 26.721.81911
assert_contains "$output" 'Unsafe candidate path'
[ -f "$case_root/redirected-candidates/26.721.81911/codex-app/candidate-sentinel" ] \
  || fail 'unsafe candidate promotion moved the redirected candidate'

case_root="$(mktemp -d "$TEST_ROOT/approvals-approve.XXXXXX")"
make_candidate "$case_root"
mkdir -p "$case_root/redirected-approvals"
ln -s "$case_root/redirected-approvals" "$case_root/runtime/approvals"
run_expect_failure_for_root "$case_root" approve 26.721.81911
assert_contains "$output" 'Unsafe approvals path'
assert_path_does_not_exist \
  "$case_root/redirected-approvals/26.721.81911.approved"

case_root="$(mktemp -d "$TEST_ROOT/approvals-promote.XXXXXX")"
make_candidate "$case_root"
mkdir -p "$case_root/redirected-approvals"
ln -s "$case_root/redirected-approvals" "$case_root/runtime/approvals"
{
  printf '%s\n' 'version=26.721.81911'
  printf '%s\n' 'build=5973'
} > "$case_root/redirected-approvals/26.721.81911.approved"
run_expect_failure_for_root "$case_root" promote 26.721.81911
assert_contains "$output" 'Unsafe approvals path'
assert_path_is_dir "$case_root/runtime/candidates/26.721.81911/codex-app"

case_root="$(mktemp -d "$TEST_ROOT/releases-promote.XXXXXX")"
make_candidate "$case_root"
make_approval "$case_root"
mkdir -p "$case_root/redirected-releases"
ln -s "$case_root/redirected-releases" "$case_root/runtime/releases"
run_expect_failure_for_root "$case_root" promote 26.721.81911
assert_contains "$output" 'Unsafe releases path'
assert_path_is_dir "$case_root/runtime/candidates/26.721.81911/codex-app"
assert_path_does_not_exist \
  "$case_root/redirected-releases/26.721.81911/codex-app"

case_root="$(mktemp -d "$TEST_ROOT/releases-rollback.XXXXXX")"
mkdir -p "$case_root/runtime" \
  "$case_root/redirected-releases/26.721.81911/codex-app"
ln -s "$case_root/redirected-releases" "$case_root/runtime/releases"
printf '%s\n' '26.721.81911' \
  > "$case_root/redirected-releases/26.721.81911/codex-app/app-version"
run_expect_failure_for_root "$case_root" rollback 26.721.81911
assert_contains "$output" 'Unsafe releases path'
assert_path_does_not_exist "$case_root/runtime/codex-app"

case_root="$(mktemp -d "$TEST_ROOT/candidate-metadata.XXXXXX")"
make_candidate "$case_root"
printf '%s\n' '5973' > "$case_root/redirected-build"
rm "$case_root/runtime/candidates/26.721.81911/codex-app/app-build"
ln -s "$case_root/redirected-build" \
  "$case_root/runtime/candidates/26.721.81911/codex-app/app-build"
run_expect_failure_for_root "$case_root" approve 26.721.81911
assert_contains "$output" 'Unsafe metadata path'
assert_path_does_not_exist "$case_root/runtime/approvals/26.721.81911.approved"

case_root="$(mktemp -d "$TEST_ROOT/release-metadata.XXXXXX")"
mkdir -p "$case_root/runtime/releases/26.721.81911/codex-app"
printf '%s\n' '26.721.81911' > "$case_root/redirected-version"
ln -s "$case_root/redirected-version" \
  "$case_root/runtime/releases/26.721.81911/codex-app/app-version"
run_expect_failure_for_root "$case_root" rollback 26.721.81911
assert_contains "$output" 'Unsafe metadata path'
assert_path_does_not_exist "$case_root/runtime/codex-app"

case_root="$(mktemp -d "$TEST_ROOT/approval-marker.XXXXXX")"
make_candidate "$case_root"
mkdir -p "$case_root/runtime/approvals"
chmod 0700 "$case_root/runtime/approvals"
printf '%s\n' 'live-sentinel-unchanged' > "$case_root/live-sentinel"
run_approve_with_legacy_marker \
  "$case_root" \
  26.721.81911 \
  "$case_root/live-sentinel"
[ "$(cat "$case_root/live-sentinel")" = 'live-sentinel-unchanged' ] \
  || fail 'approval temporary marker modified the live sentinel'
grep -Fxq 'version=26.721.81911' \
  "$case_root/runtime/approvals/26.721.81911.approved" \
  || fail 'approval marker was not atomically created after legacy marker precreation'

assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh build-candidate'
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh approve'
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh promote'
assert_file_contains "$LAB_ROOT/docs/compatibility.md" 'mint-app-<upstream-version>'

printf 'Linex release controller tests passed.\n'
