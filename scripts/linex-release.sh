#!/usr/bin/env bash
set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${LINEX_INSTALL_ROOT:-/home/nickj/codex-app-mint}"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
APPCAST_URL="${LINEX_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast.xml}"
PORT_COMMAND="${LINEX_PORT_COMMAND:-$LAB_ROOT/port-codex-app-mint.sh}"
HANDOFF_RUNNER="${LINEX_HANDOFF_RUNNER:-$LAB_ROOT/scripts/linex-handoff-runner.sh}"

APPCAST_VERSION=""
APPCAST_BUILD=""
APPCAST_ARCHIVE_URL=""
RUNTIME_REAL=""
SAFE_SUBDIR_PRESENT=""
SAFE_SUBDIR_REAL=""
RELEASES_REAL=""

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
  handoff-status
  handoff-cancel
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
appcast_request = urllib.request.Request(
    appcast_url,
    headers={"User-Agent": "Linex/1.0 (+https://github.com/nxjaime/linex-project)"},
)

with urllib.request.urlopen(appcast_request, timeout=30) as response:
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

  [ ! -L "$metadata_path" ] \
    || error "Unsafe metadata path: $metadata_path"
  [ -f "$metadata_path" ] || error "Missing $metadata_name in $runtime_dir"
  cat "$metadata_path"
}

require_safe_runtime_root() {
  local install_real=""

  [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] \
    || error "Unsafe install path: $INSTALL_ROOT"
  [ -d "$RUNTIME_ROOT" ] && [ ! -L "$RUNTIME_ROOT" ] \
    || error "Unsafe runtime path: $RUNTIME_ROOT"

  install_real="$(realpath -e "$INSTALL_ROOT")"
  RUNTIME_REAL="$(realpath -e "$RUNTIME_ROOT")"
  [ "$RUNTIME_REAL" = "$install_real/runtime" ] \
    || error "Unsafe runtime path: $RUNTIME_ROOT"
}

validate_runtime_subdir_if_present() {
  local subdir_name="$1"
  local path_label="$2"
  local subdir_path="$RUNTIME_ROOT/$subdir_name"

  require_safe_runtime_root
  SAFE_SUBDIR_PRESENT="no"
  SAFE_SUBDIR_REAL="$RUNTIME_REAL/$subdir_name"

  if [ ! -e "$subdir_path" ] && [ ! -L "$subdir_path" ]; then
    return 0
  fi

  [ -d "$subdir_path" ] && [ ! -L "$subdir_path" ] \
    || error "Unsafe $path_label path: $subdir_path"

  SAFE_SUBDIR_REAL="$(realpath -e "$subdir_path")"
  [ "$SAFE_SUBDIR_REAL" = "$RUNTIME_REAL/$subdir_name" ] \
    || error "Unsafe $path_label path: $subdir_path"
  SAFE_SUBDIR_PRESENT="yes"
}

prepare_runtime_subdir() {
  local subdir_name="$1"
  local path_label="$2"
  local subdir_path="$RUNTIME_ROOT/$subdir_name"

  validate_runtime_subdir_if_present "$subdir_name" "$path_label"
  if [ "$SAFE_SUBDIR_PRESENT" = "no" ]; then
    mkdir "$subdir_path"
    validate_runtime_subdir_if_present "$subdir_name" "$path_label"
  fi
}

validate_candidate() {
  local version="$1"
  local candidates_root="$RUNTIME_ROOT/candidates"
  local candidate_root="$candidates_root/$version"
  local candidate_dir="$RUNTIME_ROOT/candidates/$version/codex-app"
  local candidates_real=""
  local candidate_root_real=""
  local candidate_dir_real=""
  local candidate_version=""
  local candidate_build=""

  resolve_appcast_item "$version"
  validate_runtime_subdir_if_present candidates candidate
  [ "$SAFE_SUBDIR_PRESENT" = "yes" ] \
    || error "Candidate not found: $version"
  candidates_real="$SAFE_SUBDIR_REAL"

  [ -d "$candidate_root" ] && [ ! -L "$candidate_root" ] \
    || error "Unsafe candidate path: $candidate_root"
  candidate_root_real="$(realpath -e "$candidate_root")"
  [ "$candidate_root_real" = "$candidates_real/$version" ] \
    || error "Unsafe candidate path: $candidate_root"

  [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] \
    || error "Unsafe candidate path: $candidate_dir"
  candidate_dir_real="$(realpath -e "$candidate_dir")"
  [ "$candidate_dir_real" = "$candidate_root_real/codex-app" ] \
    || error "Unsafe candidate path: $candidate_dir"

  candidate_version="$(read_metadata "$candidate_dir" app-version)"
  candidate_build="$(read_metadata "$candidate_dir" app-build)"

  [ "$candidate_version" = "$APPCAST_VERSION" ] \
    || error "Candidate version mismatch: expected $APPCAST_VERSION, found $candidate_version"
  [ "$candidate_build" = "$APPCAST_BUILD" ] \
    || error "Candidate build mismatch: expected $APPCAST_BUILD, found $candidate_build"
}

validate_candidate_from_handoff() {
  local version="$1"
  local expected_build="$2"
  local candidates_root="$RUNTIME_ROOT/candidates"
  local candidate_root="$candidates_root/$version"
  local candidate_dir="$candidate_root/codex-app"
  local candidates_real=""
  local candidate_root_real=""
  local candidate_dir_real=""
  local candidate_version=""
  local candidate_build=""

  require_safe_version "$version"
  [[ "$expected_build" =~ ^[0-9]+$ ]] \
    || error "Invalid handoff build: $expected_build"
  validate_runtime_subdir_if_present candidates candidate
  [ "$SAFE_SUBDIR_PRESENT" = "yes" ] \
    || error "Candidate not found: $version"
  candidates_real="$SAFE_SUBDIR_REAL"
  [ -d "$candidate_root" ] && [ ! -L "$candidate_root" ] \
    || error "Unsafe candidate path: $candidate_root"
  candidate_root_real="$(realpath -e "$candidate_root")"
  [ "$candidate_root_real" = "$candidates_real/$version" ] \
    || error "Unsafe candidate path: $candidate_root"
  [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] \
    || error "Unsafe candidate path: $candidate_dir"
  candidate_dir_real="$(realpath -e "$candidate_dir")"
  [ "$candidate_dir_real" = "$candidate_root_real/codex-app" ] \
    || error "Unsafe candidate path: $candidate_dir"
  candidate_version="$(read_metadata "$candidate_dir" app-version)"
  candidate_build="$(read_metadata "$candidate_dir" app-build)"
  [ "$candidate_version" = "$version" ] \
    || error "Candidate version mismatch: expected $version, found $candidate_version"
  [ "$candidate_build" = "$expected_build" ] \
    || error "Candidate build mismatch: expected $expected_build, found $candidate_build"
}

prepare_candidate_path() {
  local version="$1"
  local candidates_root="$RUNTIME_ROOT/candidates"
  local candidate_root="$candidates_root/$version"
  local candidate_dir="$candidate_root/codex-app"
  local candidates_real=""
  local candidate_root_real=""
  local candidate_dir_real=""

  prepare_runtime_subdir candidates candidate
  candidates_real="$SAFE_SUBDIR_REAL"

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

  candidate_root_real="$(realpath -e "$candidate_root")"
  [ "$candidate_root_real" = "$candidates_real/$version" ] \
    || error "Unsafe candidate path: $candidate_root"

  if [ -d "$candidate_dir" ]; then
    candidate_dir_real="$(realpath -e "$candidate_dir")"
    [ "$candidate_dir_real" = "$candidate_root_real/codex-app" ] \
      || error "Unsafe candidate path: $candidate_dir"
  fi
}

prepare_cache_path() {
  local cache_root="$RUNTIME_ROOT/cache"

  prepare_runtime_subdir cache cache
  [ "$SAFE_SUBDIR_REAL" = "$RUNTIME_REAL/cache" ] \
    || error "Unsafe cache path: $cache_root"
}

validate_approvals_root_if_present() {
  validate_runtime_subdir_if_present approvals approvals
}

invalidate_approval() {
  local version="$1"
  local approval_marker="$RUNTIME_ROOT/approvals/$version.approved"

  validate_approvals_root_if_present
  if [ -e "$approval_marker" ] || [ -L "$approval_marker" ]; then
    rm -f -- "$approval_marker"
  fi
}

validate_releases_root_if_present() {
  validate_runtime_subdir_if_present releases releases
  RELEASES_REAL="$SAFE_SUBDIR_REAL"
}

validate_handoffs_root_if_present() {
  validate_runtime_subdir_if_present handoffs handoffs
}

prepare_handoffs_root() {
  validate_handoffs_root_if_present
  if [ "$SAFE_SUBDIR_PRESENT" = "no" ]; then
    install -d -m 0700 "$RUNTIME_ROOT/handoffs"
    validate_handoffs_root_if_present
  fi
  chmod 0700 "$RUNTIME_ROOT/handoffs"
}

handoff_state_path() {
  local state_name="$1"
  printf '%s\n' "$RUNTIME_ROOT/handoffs/$state_name"
}

validate_handoff_state_if_present() {
  local state_name="$1"
  local state_path="$(handoff_state_path "$state_name")"

  validate_handoffs_root_if_present
  [ "$SAFE_SUBDIR_PRESENT" = "yes" ] || return 0
  [ ! -e "$state_path" ] && [ ! -L "$state_path" ] && return 0
  [ -f "$state_path" ] && [ ! -L "$state_path" ] \
    || error "Unsafe handoff state path: $state_path"
}

write_handoff_state() {
  local state_name="$1"
  local version="$2"
  local build="$3"
  local previous_version="$4"
  local unit_name="$5"
  local state_path=""
  local temporary_path=""

  prepare_handoffs_root
  state_path="$(handoff_state_path "$state_name")"
  [ ! -e "$state_path" ] && [ ! -L "$state_path" ] \
    || error "Handoff state already exists: $state_name"

  (
    umask 077
    temporary_path="$(mktemp "$RUNTIME_ROOT/handoffs/.${state_name}.XXXXXX")"
    trap 'rm -f -- "$temporary_path"' EXIT
    {
      printf 'version=%s\n' "$version"
      printf 'build=%s\n' "$build"
      printf 'previous_version=%s\n' "$previous_version"
      printf 'unit=%s\n' "$unit_name"
    } > "$temporary_path"
    mv -Tf -- "$temporary_path" "$state_path"
    trap - EXIT
  )
}

read_handoff_state() {
  local state_name="$1"
  local state_path="$(handoff_state_path "$state_name")"
  local key=""
  local value=""

  HANDOFF_VERSION=""
  HANDOFF_BUILD=""
  HANDOFF_PREVIOUS_VERSION=""
  HANDOFF_UNIT=""
  validate_handoff_state_if_present "$state_name"
  [ -f "$state_path" ] || error "Handoff state not found: $state_name"

  while IFS='=' read -r key value; do
    case "$key" in
      version) HANDOFF_VERSION="$value" ;;
      build) HANDOFF_BUILD="$value" ;;
      previous_version) HANDOFF_PREVIOUS_VERSION="$value" ;;
      unit) HANDOFF_UNIT="$value" ;;
      *) error "Invalid handoff state: $state_name" ;;
    esac
  done < "$state_path"

  require_safe_version "$HANDOFF_VERSION"
  require_safe_version "$HANDOFF_PREVIOUS_VERSION"
  [[ "$HANDOFF_BUILD" =~ ^[0-9]+$ ]] \
    || error "Invalid handoff build: $HANDOFF_BUILD"
  [ "$HANDOFF_UNIT" = "linex-handoff-$HANDOFF_VERSION" ] \
    || error "Invalid handoff unit: $HANDOFF_UNIT"
}

remove_handoff_state() {
  local state_name="$1"
  local state_path="$(handoff_state_path "$state_name")"

  validate_handoff_state_if_present "$state_name"
  [ -f "$state_path" ] || return 0
  rm -f -- "$state_path"
}

active_runtime_version() {
  local active_dir="$RUNTIME_ROOT/codex-app"
  local active_version=""

  [ -d "$active_dir" ] || error "Active runtime not found: $active_dir"
  active_version="$(read_metadata "$active_dir" app-version)"
  require_safe_version "$active_version"
  printf '%s\n' "$active_version"
}

prepare_releases_root() {
  prepare_runtime_subdir releases releases
  RELEASES_REAL="$SAFE_SUBDIR_REAL"
}

validate_release_dir() {
  local version="$1"
  local release_parent="$RUNTIME_ROOT/releases/$version"
  local release_dir="$release_parent/codex-app"
  local release_parent_real=""
  local release_dir_real=""

  validate_releases_root_if_present
  [ "$SAFE_SUBDIR_PRESENT" = "yes" ] \
    || error "Release not found: $version"

  [ -d "$release_parent" ] && [ ! -L "$release_parent" ] \
    || error "Unsafe release path: $release_parent"
  release_parent_real="$(realpath -e "$release_parent")"
  [ "$release_parent_real" = "$RELEASES_REAL/$version" ] \
    || error "Unsafe release path: $release_parent"

  [ -d "$release_dir" ] && [ ! -L "$release_dir" ] \
    || error "Unsafe release path: $release_dir"
  release_dir_real="$(realpath -e "$release_dir")"
  [ "$release_dir_real" = "$release_parent_real/codex-app" ] \
    || error "Unsafe release path: $release_dir"
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

submit_handoff_unit() {
  local version="$1"
  local unit_name="linex-handoff-$version"
  local submit_command="${LINEX_HANDOFF_SUBMIT_COMMAND:-}"

  if [ -n "$submit_command" ]; then
    "$submit_command" "$unit_name" "$version"
    return
  fi

  [ -x "$HANDOFF_RUNNER" ] || error "Handoff runner is not executable: $HANDOFF_RUNNER"
  systemd-run --user --collect --unit="$unit_name" --property=KillMode=process \
    "--setenv=LINEX_INSTALL_ROOT=$INSTALL_ROOT" \
    "--setenv=DISPLAY=${DISPLAY:-}" \
    "--setenv=XAUTHORITY=${XAUTHORITY:-}" \
    "--setenv=XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" \
    "--setenv=DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}" \
    "$HANDOFF_RUNNER" --run "$version"
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
  invalidate_approval "$APPCAST_VERSION"
  prepare_candidate_path "$APPCAST_VERSION"
  prepare_cache_path

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

  require_safe_version "$version"
  validate_candidate "$version"

  validate_approvals_root_if_present
  if [ "$SAFE_SUBDIR_PRESENT" = "no" ]; then
    install -d -m 0700 "$approvals_dir"
    validate_approvals_root_if_present
  fi
  chmod 0700 "$approvals_dir"
  (
    umask 077
    temporary_marker="$(mktemp "$approvals_dir/.$version.approved.XXXXXX")"
    trap 'rm -f -- "$temporary_marker"' EXIT
    {
      printf 'version=%s\n' "$APPCAST_VERSION"
      printf 'build=%s\n' "$APPCAST_BUILD"
      printf 'approved_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } > "$temporary_marker"
    mv -Tf -- "$temporary_marker" "$marker_path"
    trap - EXIT
  )

  printf 'Approved candidate: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

complete_promotion() {
  local version="$1"
  local expected_build="$2"
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
  validate_approvals_root_if_present
  if [ "$SAFE_SUBDIR_PRESENT" = "no" ] \
    || { [ ! -e "$approval_marker" ] && [ ! -L "$approval_marker" ]; }; then
    error "Approve the candidate first: $version"
  fi
  [ -f "$approval_marker" ] && [ ! -L "$approval_marker" ] \
    || error "Unsafe approval marker: $approval_marker"

  validate_candidate_from_handoff "$version" "$expected_build"
  APPCAST_VERSION="$version"
  APPCAST_BUILD="$expected_build"
  grep -Fxq "version=$version" "$approval_marker" \
    || error "Approval marker version mismatch: $version"
  grep -Fxq "build=$expected_build" "$approval_marker" \
    || error "Approval marker build mismatch: $version"

  validate_releases_root_if_present
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
  prepare_releases_root

  if [ -n "$adopted_version" ]; then
    mkdir "$adopted_release_parent"
    mv "$active_dir" "$adopted_release_dir"
    switch_active_release "$adopted_version"
  fi

  mkdir "$release_parent"
  mv "$candidate_dir" "$release_dir"
  switch_active_release "$version"

  printf 'Promoted release: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

command_promote() {
  local version="$1"
  local active_version=""
  local unit_name=""
  local pending_path=""
  local running_path=""
  local release_parent="$RUNTIME_ROOT/releases/$version"

  require_safe_version "$version"
  validate_candidate "$version"
  validate_approvals_root_if_present
  [ "$SAFE_SUBDIR_PRESENT" = "yes" ] \
    && [ -f "$RUNTIME_ROOT/approvals/$version.approved" ] \
    && [ ! -L "$RUNTIME_ROOT/approvals/$version.approved" ] \
    || error "Approve the candidate first: $version"
  grep -Fxq "version=$APPCAST_VERSION" "$RUNTIME_ROOT/approvals/$version.approved" \
    || error "Approval marker version mismatch: $version"
  grep -Fxq "build=$APPCAST_BUILD" "$RUNTIME_ROOT/approvals/$version.approved" \
    || error "Approval marker build mismatch: $version"

  validate_releases_root_if_present
  [ ! -e "$release_parent" ] && [ ! -L "$release_parent" ] \
    || error "Release already exists: $version"
  active_version="$(active_runtime_version)"
  [ "$active_version" != "$version" ] \
    || error "Active and candidate versions are both $version"
  unit_name="linex-handoff-$version"
  prepare_handoffs_root
  pending_path="$(handoff_state_path pending)"
  running_path="$(handoff_state_path running)"
  [ ! -e "$pending_path" ] && [ ! -L "$pending_path" ] \
    && [ ! -e "$running_path" ] && [ ! -L "$running_path" ] \
    || error "A handoff is already pending or running"

  write_handoff_state pending "$version" "$APPCAST_BUILD" "$active_version" "$unit_name"
  if ! submit_handoff_unit "$version"; then
    remove_handoff_state pending
    error "Could not queue handoff: $version"
  fi

  printf 'Queued handoff: %s (build %s)\n' "$APPCAST_VERSION" "$APPCAST_BUILD"
}

command_handoff_status() {
  local pending_path="$(handoff_state_path pending)"
  local running_path="$(handoff_state_path running)"
  local result_path="$(handoff_state_path result)"

  validate_handoff_state_if_present pending
  if [ -f "$pending_path" ]; then
    read_handoff_state pending
    printf 'Pending handoff: %s (build %s)\n' "$HANDOFF_VERSION" "$HANDOFF_BUILD"
    return
  fi
  validate_handoff_state_if_present running
  if [ -f "$running_path" ]; then
    read_handoff_state running
    printf 'Running handoff: %s (build %s)\n' "$HANDOFF_VERSION" "$HANDOFF_BUILD"
    return
  fi
  validate_handoff_state_if_present result
  if [ -f "$result_path" ]; then
    printf 'Last handoff:\n'
    cat "$result_path"
    return
  fi
  printf 'No handoff is queued or recorded.\n'
}

command_handoff_cancel() {
  local pending_path="$(handoff_state_path pending)"

  validate_handoff_state_if_present pending
  [ -f "$pending_path" ] || error "No pending handoff to cancel"
  read_handoff_state pending
  remove_handoff_state pending
  printf 'Canceled handoff: %s\n' "$HANDOFF_VERSION"
}

command_rollback() {
  local version="$1"
  local release_dir="$RUNTIME_ROOT/releases/$version/codex-app"
  local release_version=""

  require_safe_version "$version"
  validate_release_dir "$version"

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
    handoff-status)
      require_argument_count 0 handoff-status "$@"
      command_handoff_status
      ;;
    handoff-cancel)
      require_argument_count 0 handoff-cancel "$@"
      command_handoff_cancel
      ;;
    _complete-handoff)
      require_argument_count 2 _complete-handoff "$@"
      complete_promotion "$1" "$2"
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

if [ "${LINEX_RELEASE_LIBRARY:-0}" != "1" ]; then
  main "$@"
fi
