#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

version="22.14.0"
url="$(bash "$PROJECT_DIR/scripts/managed-node.sh" print-url "$version" x64)"
test "$url" = "https://nodejs.org/dist/v${version}/node-v${version}-linux-x64.tar.xz"

dist="$TEMP_DIR/dist/v${version}"
root="$TEMP_DIR/node-v${version}-linux-x64"
mkdir -p "$dist" "$root/bin"
printf '#!/usr/bin/env bash\necho managed-node-fixture\n' > "$root/bin/node"
chmod +x "$root/bin/node"
tar -cJf "$dist/$(basename "$root").tar.xz" -C "$TEMP_DIR" "$(basename "$root")"
(cd "$dist" && sha256sum "$(basename "$root").tar.xz") > "$dist/SHASUMS256.txt"
target="$TEMP_DIR/managed-node"
CODEX_MANAGED_NODE_BASE_URL="file://$TEMP_DIR/dist" \
  bash "$PROJECT_DIR/scripts/managed-node.sh" install "$target" "$TEMP_DIR/cache" "$version" x64
test -x "$target/bin/node"
grep -Fq managed-node-fixture "$target/bin/node"

grep -Fq 'resources/managed-node/bin/node' "$PROJECT_DIR/port-codex-app-mint.sh"
grep -Fq 'CODEX_MANAGED_NODE_PATH' "$PROJECT_DIR/port-codex-app-mint.sh"

printf 'Managed Node tests passed.\n'
