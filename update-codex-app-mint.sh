#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$SCRIPT_DIR/runtime"
INSTALL_DIR="$RUNTIME_ROOT/codex-app"
STAGING_ROOT="$SCRIPT_DIR/runtime-update"
APPCAST_URL="https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
ELECTRON_VERSION="${CODEX_ELECTRON_VERSION:-40.0.0}"

latest_version() {
  curl -fsSL --connect-timeout 30 --max-time 120 "$APPCAST_URL" |
    python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("No release found in appcast")
version = item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString")
if not version:
    raise SystemExit("Release version missing from appcast")
print(version)
'
}

installed_version() {
  if [ -s "$INSTALL_DIR/app-version" ]; then
    cat "$INSTALL_DIR/app-version"
    return
  fi
  printf 'unknown\n'
}

main() {
  local latest=""
  local installed=""
  local backup_dir=""

  latest="$(latest_version)"
  installed="$(installed_version)"

  printf 'Installed Codex App: %s\n' "$installed"
  printf 'Latest Codex App:    %s\n' "$latest"

  if [ "$installed" = "$latest" ]; then
    echo "Codex App is already current."
    return
  fi

  if [ ! -s "$STAGING_ROOT/codex-app/app-version" ] ||
    [ "$(cat "$STAGING_ROOT/codex-app/app-version")" != "$latest" ]; then
    rm -rf "$STAGING_ROOT"
    CODEX_ELECTRON_VERSION="$ELECTRON_VERSION" \
      CODEX_PORT_OUTPUT_ROOT="$STAGING_ROOT" \
      "$SCRIPT_DIR/port-codex-app-mint.sh" --fresh --skip-desktop-entry
  else
    echo "Using already staged Codex App $latest."
  fi

  [ "$(cat "$STAGING_ROOT/codex-app/app-version")" = "$latest" ] ||
    {
      echo "Staged version does not match the official release feed." >&2
      exit 1
    }

  if pgrep -f "$INSTALL_DIR/(electron|start.sh)" >/dev/null 2>&1; then
    echo "Close Codex Desktop, then run this updater again to install the staged release." >&2
    exit 2
  fi

  backup_dir="$RUNTIME_ROOT/codex-app-${installed}-backup"
  [ ! -e "$backup_dir" ] || backup_dir="${backup_dir}-$(date +%Y%m%d%H%M%S)"

  mv "$INSTALL_DIR" "$backup_dir"
  mv "$STAGING_ROOT/codex-app" "$INSTALL_DIR"

  echo "Updated Codex App to $latest."
  echo "Previous runtime: $backup_dir"
}

main "$@"
