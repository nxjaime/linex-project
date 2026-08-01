#!/usr/bin/env bash
set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROLLER="$LAB_ROOT/scripts/linex-release.sh"
RUNNER="$LAB_ROOT/scripts/linex-handoff-runner.sh"
TEST_ROOT="$(mktemp -d)"
LIVE_ROOT="$TEST_ROOT/live"
APPCAST="$TEST_ROOT/appcast.xml"
PROCESS_STATE="$TEST_ROOT/process-state"
SUBMIT_LOG="$TEST_ROOT/submit.log"
LAUNCH_LOG="$TEST_ROOT/launch.log"
FAKE_PORT="$TEST_ROOT/fake-port"
FAKE_SMOKE="$TEST_ROOT/fake-smoke"
FAKE_ACCEPTANCE="$TEST_ROOT/fake-acceptance"
FAKE_CHECK="$TEST_ROOT/process-check"
FAKE_SUBMIT="$TEST_ROOT/submit"
FAKE_LAUNCH="$TEST_ROOT/launch"
output=""

export PROCESS_STATE SUBMIT_LOG LAUNCH_LOG

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain '$2', got: $1" ;;
  esac
}

assert_link_target() {
  [ "$(readlink -f "$1")" = "$2" ] \
    || fail "expected $1 to resolve to $2"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "expected $1 to contain '$2'"
}

run_controller() {
  if ! output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$FAKE_CHECK" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "controller failed: $*"$'\n'"$output"
  fi
}

run_controller_failure() {
  if output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_APPCAST_URL="file://$APPCAST" \
    LINEX_PORT_COMMAND="$FAKE_PORT" \
    LINEX_SMOKE_TEST_COMMAND="$FAKE_SMOKE" \
    LINEX_ACCEPTANCE_TEST_COMMAND="$FAKE_ACCEPTANCE" \
    LINEX_PROCESS_CHECK_COMMAND="$FAKE_CHECK" \
    LINEX_HANDOFF_SUBMIT_COMMAND="$FAKE_SUBMIT" \
      "$CONTROLLER" "$@" 2>&1
  )"; then
    fail "controller unexpectedly succeeded: $*"
  fi
}

run_runner() {
  local version="$1"

  if ! output="$(
    LINEX_INSTALL_ROOT="$LIVE_ROOT" \
    LINEX_PROCESS_CHECK_COMMAND="$FAKE_CHECK" \
    LINEX_HANDOFF_LAUNCH_COMMAND="$FAKE_LAUNCH" \
    LINEX_HANDOFF_HEALTH_SECONDS=1 \
      "$RUNNER" --run "$version" 2>&1
  )"; then
    fail "runner failed"$'\n'"$output"
  fi
}

mkdir -p "$LIVE_ROOT/runtime/codex-app"
printf '%s\n' '26.700.10000' > "$LIVE_ROOT/runtime/codex-app/app-version"
printf '%s\n' '7000' > "$LIVE_ROOT/runtime/codex-app/app-build"
printf '%s\n' 'baseline' > "$LIVE_ROOT/runtime/codex-app/sentinel"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$LIVE_ROOT/runtime/codex-app/start.sh"
chmod +x "$LIVE_ROOT/runtime/codex-app/start.sh"
printf '%s\n' running > "$PROCESS_STATE"

cat > "$APPCAST" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:shortVersionString>26.800.10000</sparkle:shortVersionString><sparkle:version>8000</sparkle:version><enclosure url="https://example.invalid/Codex-10000.zip" /></item>
<item><sparkle:shortVersionString>26.800.20000</sparkle:shortVersionString><sparkle:version>8001</sparkle:version><enclosure url="https://example.invalid/Codex-20000.zip" /></item>
</channel></rss>
XML

cat > "$FAKE_PORT" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$CODEX_PORT_SOURCE_URL" in
  *Codex-10000.zip) version=26.800.10000; build=8000 ;;
  *Codex-20000.zip) version=26.800.20000; build=8001 ;;
  *) exit 9 ;;
esac
mkdir -p "$CODEX_PORT_INSTALL_DIR"
printf '%s\n' "$version" > "$CODEX_PORT_INSTALL_DIR/app-version"
printf '%s\n' "$build" > "$CODEX_PORT_INSTALL_DIR/app-build"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$CODEX_PORT_INSTALL_DIR/start.sh"
chmod +x "$CODEX_PORT_INSTALL_DIR/start.sh"
SH

cat > "$FAKE_CHECK" <<'SH'
#!/usr/bin/env bash
case "$(cat "$PROCESS_STATE")" in
  running) exit 0 ;;
  stopped) exit 1 ;;
  *) exit 7 ;;
esac
SH

cat > "$FAKE_SMOKE" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_ACCEPTANCE" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_SUBMIT" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUBMIT_LOG"
SH

cat > "$FAKE_LAUNCH" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$1" >> "$LAUNCH_LOG"
case "$1" in
  */releases/26.800.10000/codex-app/start.sh) exit 1 ;;
  */releases/26.800.20000/codex-app/start.sh) sleep 2 ;;
  */releases/26.700.10000/codex-app/start.sh) sleep 2 ;;
  *) exit 8 ;;
esac
SH

chmod +x "$FAKE_PORT" "$FAKE_SMOKE" "$FAKE_ACCEPTANCE" "$FAKE_CHECK" \
  "$FAKE_SUBMIT" "$FAKE_LAUNCH"

run_controller build-candidate 26.800.10000
run_controller approve 26.800.10000
run_controller promote 26.800.10000
assert_contains "$output" 'Queued handoff: 26.800.10000'
[ -f "$LIVE_ROOT/runtime/handoffs/pending" ] || fail 'promotion did not create pending handoff'
[ -d "$LIVE_ROOT/runtime/codex-app" ] || fail 'promotion changed live runtime while app was running'
assert_contains "$(cat "$SUBMIT_LOG")" 'linex-handoff-26.800.10000'

run_controller handoff-status
assert_contains "$output" 'Pending handoff: 26.800.10000'
run_controller_failure promote 26.800.10000
assert_contains "$output" 'A handoff is already pending'
run_controller handoff-cancel
[ ! -e "$LIVE_ROOT/runtime/handoffs/pending" ] || fail 'cancel did not remove pending handoff'

run_controller promote 26.800.10000
printf '%s\n' stopped > "$PROCESS_STATE"
run_runner 26.800.10000
assert_link_target \
  "$LIVE_ROOT/runtime/codex-app" \
  "$LIVE_ROOT/runtime/releases/26.700.10000/codex-app"
assert_contains "$(cat "$LIVE_ROOT/runtime/handoffs/result")" 'status=rolled_back'
assert_contains "$(cat "$LAUNCH_LOG")" 'releases/26.800.10000/codex-app/start.sh'
assert_contains "$(cat "$LAUNCH_LOG")" 'releases/26.700.10000/codex-app/start.sh'

run_controller build-candidate 26.800.20000
run_controller approve 26.800.20000
run_controller promote 26.800.20000
run_runner 26.800.20000
assert_link_target \
  "$LIVE_ROOT/runtime/codex-app" \
  "$LIVE_ROOT/runtime/releases/26.800.20000/codex-app"
assert_contains "$(cat "$LIVE_ROOT/runtime/handoffs/result")" 'status=succeeded'
assert_contains "$(cat "$LAUNCH_LOG")" 'releases/26.800.20000/codex-app/start.sh'

assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh handoff-status'
assert_file_contains "$LAB_ROOT/README.md" './scripts/linex-release.sh handoff-cancel'
assert_file_contains "$LAB_ROOT/README.md" '45 seconds'
assert_file_contains "$LAB_ROOT/docs/compatibility.md" 'queued handoff'

printf 'Linex handoff tests passed.\n'
