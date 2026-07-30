#!/usr/bin/env bash
set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${LINEX_INSTALL_ROOT:-/home/nickj/codex-app-mint}"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
APPCAST_URL="${LINEX_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast.xml}"
PORT_COMMAND="${LINEX_PORT_COMMAND:-$LAB_ROOT/port-codex-app-mint.sh}"

APPCAST_VERSION=""
APPCAST_BUILD=""
APPCAST_ARCHIVE_URL=""

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/linex-release.sh COMMAND [VERSION]

Commands:
  check
  build-candidate [version]
  approve <version>
  promote <version>
  rollback <version>
EOF
}

require_safe_version() {
  local version="$1"

  [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] \
    || error "Invalid version: $version"
}

require_argument_count() {
  local expected="$1"
  local command_name="$2"
  shift 2

  [ "$#" -eq "$expected" ] \
    || error "$command_name expects $expected argument(s)"
}

read_appcast_item() {
  local requested_version="$1"

  APPCAST_URL="$APPCAST_URL" REQUESTED_VERSION="$requested_version" python3 - <<'PY'
import os
import urllib.request
import xml.etree.ElementTree as ET

appcast_url = os.environ["APPCAST_URL"]
requested = os.environ["REQUESTED_VERSION"]

with urllib.request.urlopen(appcast_url, timeout=30) as response:
    root = ET.fromstring(response.read())

sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = root.findall("./channel/item")
if not items:
    raise SystemExit("Appcast contains no release items")

selected = None
for item in items:
    version = (item.findtext(sparkle + "shortVersionString") or "").strip()
    if not requested or version == requested:
        selected = item
        break

if selected is None:
    raise SystemExit(f"Unknown appcast version: {requested}")

version = (selected.findtext(sparkle + "shortVersionString") or "").strip()
build = (selected.findtext(sparkle + "version") or "").strip()
enclosure = selected.find("enclosure")
archive_url = enclosure.get("url", "").strip() if enclosure is not None else ""

if not version or not build or not archive_url:
    raise SystemExit("Appcast item is missing version, build, or enclosure URL")
if any("\t" in value or "\n" in value for value in (version, build, archive_url)):
    raise SystemExit("Appcast item contains invalid metadata")

print(f"{version}\t{build}\t{archive_url}")
PY
}

resolve_appcast_item() {
  local requested_version="$1"
  local item=""

  item="$(read_appcast_item "$requested_version")"
  IFS=$'\t' read -r APPCAST_VERSION APPCAST_BUILD APPCAST_ARCHIVE_URL <<< "$item"

  [ -n "$APPCAST_VERSION" ] \
    && [ -n "$APPCAST_BUILD" ] \
    && [ -n "$APPCAST_ARCHIVE_URL" ] \
    || error "Could not parse appcast release metadata"

  require_safe_version "$APPCAST_VERSION"
}

read_metadata() {
  local runtime_dir="$1"
  local metadata_name="$2"
  local metadata_path="$runtime_dir/$metadata_name"

  [ -f "$metadata_path" ] || error "Missing $metadata_name in $runtime_dir"
  cat "$metadata_path"
}

validate_candidate() {
  local version="$1"
  local candidate_dir="$RUNTIME_ROOT/candidates/$version/codex-app"
  local candidate_version=""
  local candidate_build=""

  resolve_appcast_item "$version"
  [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] \
    || error "Candidate not found: $version"

  candidate_version="$(read_metadata "$candidate_dir" app-version)"
  candidate_build="$(read_metadata "$candidate_dir" app-build)"

  [ "$candidate_version" = "$APPCAST_VERSION" ] \
    || error "Candidate version mismatch: expected $APPCAST_VERSION, found $candidate_version"
  [ "$candidate_build" = "$APPCAST_BUILD" ] \
    || error "Candidate build mismatch: expected $APPCAST_BUILD, found $candidate_build"
}

prepare_candidate_path() {
  local version="$1"
  local candidates_root="$RUNTIME_ROOT/candidates"
  local candidate_root="$candidates_root/$version"
  local candidate_dir="$candidate_root/codex-app"
  local candidates_real=""
  local candidate_root_real=""
  local candidate_dir_real=""

  if [ -e "$candidates_root" ] || [ -L "$candidates_root" ]; then
    [ -d "$candidates_root" ] && [ ! -L "$candidates_root" ] \
      || error "Unsafe candidate path: $candidates_root"
  else
    mkdir -p "$candidates_root"
  fi

  if [ -e "$candidate_root" ] || [ -L "$candidate_root" ]; then
    [ -d "$candidate_root" ] && [ ! -L "$candidate_root" ] \
      || error "Unsafe candidate path: $candidate_root"
  else
    mkdir "$candidate_root"
  fi

  if [ -e "$candidate_dir" ] || [ -L "$candidate_dir" ]; then
    [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] \
      || error "Unsafe candidate path: $candidate_dir"
  fi

  candidates_real="$(realpath -e "$candidates_root")"
  candidate_root_real="$(realpath -e "$candidate_root")"
  [ "$candidate_root_real" = "$candidates_real/$version" ] \
    || error "Unsafe candidate path: $candidate_root"

  if [ -d "$candidate_dir" ]; then
    candidate_dir_real="$(realpath -e "$candidate_dir")"
    [ "$candidate_dir_real" = "$candidate_root_real/codex-app" ] \
      || error "Unsafe candidate path: $candidate_dir"
  fi
}

run_smoke_test() {
  local candidate_dir="$1"

  if [ -n "${LINEX_SMOKE_TEST_COMMAND:-}" ]; then
    CODEX_APP_RUNTIME_DIR="$candidate_dir" "$LINEX_SMOKE_TEST_COMMAND"
  else
    CODEX_APP_RUNTIME_DIR="$candidate_dir" \
      node "$LAB_ROOT/tests/linux-automation-smoke.mjs"
  fi
}

run_acceptance_test() {
  local candidate_dir="$1"

  if [ -n "${LINEX_ACCEPTANCE_TEST_COMMAND:-}" ]; then
    CODEX_APP_RUNTIME_DIR="$candidate_dir" "$LINEX_ACCEPTANCE_TEST_COMMAND"
  else
    CODEX_APP_RUNTIME_DIR="$candidate_dir" \
      node "$LAB_ROOT/tests/computer-use-acceptance.mjs"
  fi
}

escape_ere_literal() {
  LC_ALL=C sed 's/[][\\.^$*+?(){}|]/\\&/g' <<< "$1"
}

ensure_not_running() {
  local process_status=0
  local process_pattern=""

  if [ -n "${LINEX_PROCESS_CHECK_COMMAND:-}" ]; then
    if "$LINEX_PROCESS_CHECK_COMMAND" >/dev/null 2>&1; then
      process_status=0
    else
      process_status=$?
    fi
  else
    process_pattern="$(escape_ere_literal "$RUNTIME_ROOT")/codex-app/(electron|start.sh)"
    if pgrep -f "$process_pattern" >/dev/null 2>&1; then
      process_status=0
    else
      process_status=$?
    fi
  fi

  case "$process_status" in
    0) error "The desktop app is running; close it before changing releases" ;;
    1) return 0 ;;
    *) error "The process check failed with exit code $process_status" ;;
  esac
}

switch_active_release() {
  local version="$1"
  local next_link="$RUNTIME_ROOT/.codex-app.next"

  [ ! -e "$next_link" ] && [ ! -L "$next_link" ] \
    || error "Temporary release link already exists: $next_link"

  ln -s "releases/$version/codex-app" "$next_link"
  mv -Tf "$next_link" "$RUNTIME_ROOT/codex-app"
}

command_check() {
  local active_dir="$RUNTIME_ROOT/codex-app"
  local active_version="not installed"
  local active_build="unknown"
  local candidate_status="no"

  resolve_appcast_item ""

  if [ -d "$active_dir" ]; then
    if [ -f "$active_dir/app-version" ]; then
      active_version="$(cat "$active_dir/app-version")"
    else
      active_version="unknown"
    fi
    if [ -f "$active_dir/app-build" ]; then
      active_build="$(cat "$active_dir/app-build")"
    fi
  fi

  if [ -d "$RUNTIME_ROOT/candidates/$APPCAST_VERSION/codex-app" ]; then
    candidate_status="yes"
  fi

  printf 'Latest upstream: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
  printf 'Active runtime: %s (build %s)\n' "$active_version" "$active_build"
  printf 'Candidate for latest upstream: %s\n' "$candidate_status"
}

command_build_candidate() {
  local requested_version="${1:-}"
  local candidate_root=""
  local candidate_dir=""

  if [ -n "$requested_version" ]; then
    require_safe_version "$requested_version"
  fi
  resolve_appcast_item "$requested_version"

  candidate_root="$RUNTIME_ROOT/candidates/$APPCAST_VERSION"
  candidate_dir="$candidate_root/codex-app"
  prepare_candidate_path "$APPCAST_VERSION"

  CODEX_PORT_OUTPUT_ROOT="$candidate_root" \
  CODEX_PORT_INSTALL_DIR="$candidate_dir" \
  CODEX_PORT_CACHE_DIR="$RUNTIME_ROOT/cache" \
  CODEX_PORT_SOURCE_URL="$APPCAST_ARCHIVE_URL" \
    "$PORT_COMMAND" --fresh --skip-desktop-entry

  validate_candidate "$APPCAST_VERSION"
  run_smoke_test "$candidate_dir"
  run_acceptance_test "$candidate_dir"

  printf 'Candidate ready: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

command_approve() {
  local version="$1"
  local approvals_dir="$RUNTIME_ROOT/approvals"
  local marker_path="$approvals_dir/$version.approved"
  local temporary_marker="$approvals_dir/.$version.approved.$$"

  require_safe_version "$version"
  validate_candidate "$version"

  install -d -m 0700 "$approvals_dir"
  chmod 0700 "$approvals_dir"
  (
    umask 077
    {
      printf 'version=%s\n' "$APPCAST_VERSION"
      printf 'build=%s\n' "$APPCAST_BUILD"
      printf 'approved_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } > "$temporary_marker"
  )
  mv -f "$temporary_marker" "$marker_path"

  printf 'Approved candidate: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

command_promote() {
  local version="$1"
  local candidate_dir="$RUNTIME_ROOT/candidates/$version/codex-app"
  local approval_marker="$RUNTIME_ROOT/approvals/$version.approved"
  local releases_root="$RUNTIME_ROOT/releases"
  local release_parent="$releases_root/$version"
  local release_dir="$release_parent/codex-app"
  local active_dir="$RUNTIME_ROOT/codex-app"
  local adopted_version=""
  local adopted_release_parent=""
  local adopted_release_dir=""

  require_safe_version "$version"
  [ -f "$approval_marker" ] \
    || error "Approve the candidate first: $version"

  validate_candidate "$version"
  grep -Fxq "version=$APPCAST_VERSION" "$approval_marker" \
    || error "Approval marker version mismatch: $version"
  grep -Fxq "build=$APPCAST_BUILD" "$approval_marker" \
    || error "Approval marker build mismatch: $version"

  [ ! -e "$release_parent" ] && [ ! -L "$release_parent" ] \
    || error "Release already exists: $version"

  if [ -L "$active_dir" ]; then
    :
  elif [ -d "$active_dir" ]; then
    adopted_version="$(read_metadata "$active_dir" app-version)"
    require_safe_version "$adopted_version"
    adopted_release_parent="$releases_root/$adopted_version"
    adopted_release_dir="$adopted_release_parent/codex-app"
    [ "$adopted_release_dir" != "$release_dir" ] \
      || error "Active and candidate versions are both $version"
    [ ! -e "$adopted_release_parent" ] && [ ! -L "$adopted_release_parent" ] \
      || error "Release already exists for active runtime: $adopted_version"
  elif [ -e "$active_dir" ]; then
    error "Active runtime is neither a directory nor a symlink: $active_dir"
  fi

  ensure_not_running
  mkdir -p "$releases_root"

  if [ -n "$adopted_version" ]; then
    mkdir -p "$adopted_release_parent"
    mv "$active_dir" "$adopted_release_dir"
    switch_active_release "$adopted_version"
  fi

  mkdir -p "$release_parent"
  mv "$candidate_dir" "$release_dir"
  switch_active_release "$version"

  printf 'Promoted release: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

command_rollback() {
  local version="$1"
  local release_dir="$RUNTIME_ROOT/releases/$version/codex-app"
  local release_version=""

  require_safe_version "$version"
  [ -d "$release_dir" ] && [ ! -L "$release_dir" ] \
    || error "Release not found: $version"

  release_version="$(read_metadata "$release_dir" app-version)"
  [ "$release_version" = "$version" ] \
    || error "Release version mismatch: expected $version, found $release_version"

  ensure_not_running
  switch_active_release "$version"

  printf 'Rolled back to release: %s\n' "$version"
}

main() {
  local command_name="${1:-}"

  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command_name" in
    check)
      require_argument_count 0 check "$@"
      command_check
      ;;
    build-candidate)
      [ "$#" -le 1 ] || error "build-candidate expects at most 1 argument"
      command_build_candidate "${1:-}"
      ;;
    approve)
      require_argument_count 1 approve "$@"
      command_approve "$1"
      ;;
    promote)
      require_argument_count 1 promote "$@"
      command_promote "$1"
      ;;
    rollback)
      require_argument_count 1 rollback "$@"
      command_rollback "$1"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      error "Unknown command: ${command_name:-<none>}"
      ;;
  esac
}

main "$@"
