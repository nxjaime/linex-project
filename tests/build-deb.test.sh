#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

RUNTIME="$TEMP_DIR/codex-app"
OUTPUT="$TEMP_DIR/linex-codex.deb"
mkdir -p "$RUNTIME/resources" "$RUNTIME/content/webview"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$RUNTIME/start.sh"
chmod +x "$RUNTIME/start.sh"
printf '26.900.10000\n' > "$RUNTIME/app-version"
printf '7000\n' > "$RUNTIME/app-build"
printf 'placeholder\n' > "$RUNTIME/resources/app.asar"
printf '<!doctype html>\n' > "$RUNTIME/content/webview/index.html"

bash "$PROJECT_DIR/scripts/build-deb.sh" "$RUNTIME" "$OUTPUT"

test "$(dpkg-deb -f "$OUTPUT" Package)" = "linex-codex"
test "$(dpkg-deb -f "$OUTPUT" Version)" = "26.900.10000"
contents="$(dpkg-deb -c "$OUTPUT")"
grep -Fq './opt/linex-codex/start.sh' <<< "$contents"
grep -Fq './usr/bin/linex-codex' <<< "$contents"
grep -Fq './usr/share/applications/codex-desktop.desktop' <<< "$contents"

printf 'Debian package tests passed.\n'
