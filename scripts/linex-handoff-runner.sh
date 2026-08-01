#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="$SCRIPT_DIR/linex-release.sh"
INSTALL_ROOT="${LINEX_INSTALL_ROOT:-/home/nickj/codex-app-mint}"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
HEALTH_SECONDS="${LINEX_HANDOFF_HEALTH_SECONDS:-45}"

LINEX_RELEASE_LIBRARY=1 source "$CONTROLLER"

handoff_log() {
  prepare_handoffs_root
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" \
    >> "$RUNTIME_ROOT/handoffs/handoff.log"
}

write_handoff_result() {
  local status="$1"
  local detail="$2"
  local result_path="$(handoff_state_path result)"
  local temporary_path=""

  prepare_handoffs_root
  validate_handoff_state_if_present result
  rm -f -- "$result_path"
  (
    umask 077
    temporary_path="$(mktemp "$RUNTIME_ROOT/handoffs/.result.XXXXXX")"
    trap 'rm -f -- "$temporary_path"' EXIT
    {
      printf 'status=%s\n' "$status"
      printf 'version=%s\n' "$HANDOFF_VERSION"
      printf 'previous_version=%s\n' "$HANDOFF_PREVIOUS_VERSION"
      printf 'completed_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      printf 'detail=%s\n' "$detail"
    } > "$temporary_path"
    mv -Tf -- "$temporary_path" "$result_path"
    trap - EXIT
  )
}

notify_handoff() {
  local summary="$1"
  local body="$2"

  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$summary" "$body" >/dev/null 2>&1 || true
  fi
}

process_status() {
  local process_pattern=""

  if [ -n "${LINEX_PROCESS_CHECK_COMMAND:-}" ]; then
    "$LINEX_PROCESS_CHECK_COMMAND"
    return
  fi
  process_pattern="$(escape_ere_literal "$RUNTIME_ROOT")/codex-app/(electron|start.sh)"
  pgrep -f "$process_pattern" >/dev/null 2>&1
}

launch_active_release() {
  local version="$1"
  local active_start="$RUNTIME_ROOT/codex-app/start.sh"
  local resolved_start=""

  [ -x "$active_start" ] || return 1
  resolved_start="$(realpath -e "$active_start")"
  case "$resolved_start" in
    "$RUNTIME_ROOT/releases/$version/codex-app/start.sh") ;;
    *) return 1 ;;
  esac

  if [ -n "${LINEX_HANDOFF_LAUNCH_COMMAND:-}" ]; then
    "$LINEX_HANDOFF_LAUNCH_COMMAND" "$resolved_start" &
  else
    "$active_start" >> "$RUNTIME_ROOT/handoffs/handoff.log" 2>&1 &
  fi
  HANDOFF_LAUNCH_PID=$!
}

wait_for_launch_health() {
  local remaining="$HEALTH_SECONDS"

  [[ "$remaining" =~ ^[0-9]+$ ]] || return 2
  while [ "$remaining" -gt 0 ]; do
    sleep 1
    kill -0 "$HANDOFF_LAUNCH_PID" 2>/dev/null || return 1
    remaining=$((remaining - 1))
  done
  return 0
}

finish_handoff() {
  local status="$1"
  local detail="$2"

  handoff_log "$status: $detail"
  write_handoff_result "$status" "$detail"
  remove_handoff_state running
}

rollback_and_report() {
  local detail="$1"

  if "$CONTROLLER" rollback "$HANDOFF_PREVIOUS_VERSION"; then
    if launch_active_release "$HANDOFF_PREVIOUS_VERSION"; then
      finish_handoff rolled_back "$detail"
      notify_handoff 'Linex handoff rolled back' "$HANDOFF_PREVIOUS_VERSION was relaunched"
      return 0
    fi
    finish_handoff failed "rollback switched release but could not relaunch prior runtime"
  else
    finish_handoff failed "rollback failed after replacement startup failure"
  fi
  notify_handoff 'Linex handoff failed' 'See the local handoff result and journal.'
  return 1
}

run_handoff() {
  local requested_version="$1"
  local pending_path="$(handoff_state_path pending)"
  local running_path="$(handoff_state_path running)"
  local process_check=""

  require_safe_version "$requested_version"
  read_handoff_state pending
  [ "$HANDOFF_VERSION" = "$requested_version" ] \
    || error "Queued handoff version mismatch: $requested_version"
  mv -T "$pending_path" "$running_path"

  while true; do
    if process_status; then
      sleep 1
      continue
    else
      process_check=$?
    fi
    case "$process_check" in
      1) break ;;
      *) finish_handoff failed "process check failed with exit code $process_check"; return 1 ;;
    esac
  done

  handoff_log "switching to $HANDOFF_VERSION"
  if ! "$CONTROLLER" _complete-handoff "$HANDOFF_VERSION" "$HANDOFF_BUILD"; then
    finish_handoff failed 'promotion failed after the desktop app exited'
    notify_handoff 'Linex handoff failed' 'The approved release was not activated.'
    return 1
  fi
  if ! launch_active_release "$HANDOFF_VERSION"; then
    rollback_and_report 'replacement could not be launched'
    return
  fi
  if wait_for_launch_health; then
    finish_handoff succeeded 'replacement remained running through health window'
    notify_handoff 'Linex handoff complete' "$HANDOFF_VERSION is now active"
    return
  fi
  rollback_and_report 'replacement exited during startup health check'
}

main() {
  [ "$#" -eq 2 ] && [ "$1" = '--run' ] \
    || error 'Usage: scripts/linex-handoff-runner.sh --run <version>'
  run_handoff "$2"
}

main "$@"
