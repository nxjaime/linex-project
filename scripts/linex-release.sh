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
  validate_approvals_root_if_present
  if [ "$SAFE_SUBDIR_PRESENT" = "no" ] \
    || { [ ! -e "$approval_marker" ] && [ ! -L "$approval_marker" ]; }; then
    error "Approve the candidate first: $version"
  fi
  [ -f "$approval_marker" ] && [ ! -L "$approval_marker" ] \
    || error "Unsafe approval marker: $approval_marker"

  validate_candidate "$version"
  grep -Fxq "version=$APPCAST_VERSION" "$approval_marker" \
    || error "Approval marker version mismatch: $version"
  grep -Fxq "build=$APPCAST_BUILD" "$approval_marker" \
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
