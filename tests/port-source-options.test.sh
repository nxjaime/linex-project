#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
FIXTURE="$TEMP_DIR/source-parser-fixture.sh"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

assert_contains() {
  local text="$1"
  local expected="$2"

  case "$text" in
    *"$expected"*) ;;
    *)
      printf 'Expected output to contain: %s\n' "$expected" >&2
      printf 'Actual output:\n%s\n' "$text" >&2
      exit 1
      ;;
  esac
}

# Source the parser without invoking the script's main build flow.
sed '/^main "\$@"$/d' "$PROJECT_DIR/port-codex-app-mint.sh" > "$FIXTURE"

output="$(
  # shellcheck source=/dev/null
  source "$FIXTURE"
  parse_args --archive "$TEMP_DIR/Codex.zip"
  usage
)"

assert_contains "$output" 'CODEX_PORT_SOURCE_URL'
assert_contains "$output" '--archive PATH'
assert_contains "$output" '--dmg PATH'

printf 'Source option tests passed.\n'
