#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DESKTOP_TEMPLATE="$PROJECT_DIR/templates/codex-desktop.desktop.in"
PACKAGE_NAME="${LINEX_DEB_PACKAGE_NAME:-linex-codex}"

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/build-deb.sh RUNTIME_DIR OUTPUT.deb

Build a manual Debian package from an already-built Linex runtime.
This command only creates the artifact; it never installs or promotes it.
EOF
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
RUNTIME_DIR="$1"
OUTPUT_PATH="$2"

[ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] || error "Runtime directory must be a real directory: $RUNTIME_DIR"
[ -x "$RUNTIME_DIR/start.sh" ] || error "Runtime launcher is missing or not executable: $RUNTIME_DIR/start.sh"
[ -f "$RUNTIME_DIR/app-version" ] || error "Runtime app-version is missing"
[ -f "$RUNTIME_DIR/app-build" ] || error "Runtime app-build is missing"
[ -f "$DESKTOP_TEMPLATE" ] || error "Desktop template is missing: $DESKTOP_TEMPLATE"
command -v dpkg-deb >/dev/null 2>&1 || error "dpkg-deb is required to build a Debian package"

VERSION="$(tr -d '\n' < "$RUNTIME_DIR/app-version")"
BUILD="$(tr -d '\n' < "$RUNTIME_DIR/app-build")"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || error "Unsafe Debian package version: $VERSION"
[[ "$BUILD" =~ ^[0-9]+$ ]] || error "Unsafe app build number: $BUILD"
PACKAGE_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
[ -n "$PACKAGE_ARCH" ] || error "Could not determine the Debian architecture"

OUTPUT_PATH="$(realpath -m "$OUTPUT_PATH")"
mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p \
  "$STAGE_DIR/DEBIAN" \
  "$STAGE_DIR/opt/linex-codex" \
  "$STAGE_DIR/usr/bin" \
  "$STAGE_DIR/usr/share/applications"

cp -a "$RUNTIME_DIR/." "$STAGE_DIR/opt/linex-codex/"

cat > "$STAGE_DIR/usr/bin/linex-codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/linex-codex/start.sh "$@"
EOF
chmod 0755 "$STAGE_DIR/usr/bin/linex-codex"

sed \
  -e 's|__EXEC__|/usr/bin/linex-codex|g' \
  -e 's|__ICON__|/opt/linex-codex/codex.png|g' \
  "$DESKTOP_TEMPLATE" > "$STAGE_DIR/usr/share/applications/codex-desktop.desktop"

cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $PACKAGE_ARCH
Maintainer: Linex maintainers <linex-project@users.noreply.github.com>
Description: Codex desktop compatibility runtime for Linux Mint
 Local Linux runtime built from the user's authorized upstream Codex archive.
 This package contains the verified runtime only and does not install updates.
EOF

dpkg-deb --build --root-owner-group "$STAGE_DIR" "$OUTPUT_PATH" >/dev/null
printf 'Built Debian package: %s (version %s, build %s)\n' "$OUTPUT_PATH" "$VERSION" "$BUILD"
