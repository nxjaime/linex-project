#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_VERSION="22.14.0"
BASE_URL="${CODEX_MANAGED_NODE_BASE_URL:-https://nodejs.org/dist}"

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/managed-node.sh print-url VERSION ARCH
  scripts/managed-node.sh install TARGET_DIR CACHE_DIR [VERSION] [ARCH]

ARCH is the Node release architecture (`x64` or `arm64`).
EOF
}

node_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64|x64) printf 'x64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) error "Unsupported managed Node architecture: ${1:-$(uname -m)}" ;;
  esac
}

archive_name() {
  local version="$1"
  local arch="$2"
  printf 'node-v%s-linux-%s.tar.xz\n' "$version" "$arch"
}

archive_url() {
  local version="$1"
  local arch="$2"
  printf '%s/v%s/%s\n' "${BASE_URL%/}" "$version" "$(archive_name "$version" "$arch")"
}

manifest_url() {
  local version="$1"
  printf '%s/v%s/SHASUMS256.txt\n' "${BASE_URL%/}" "$version"
}

install_managed_node() {
  local target_dir="$1"
  local cache_dir="$2"
  local version="${3:-$DEFAULT_VERSION}"
  local arch="$(node_arch "${4:-$(uname -m)}")"
  local archive="$(archive_name "$version" "$arch")"
  local archive_path="$cache_dir/$archive"
  local manifest_path="$cache_dir/SHASUMS256-v${version}.txt"
  local expected_hash=""
  local actual_hash=""
  local extract_dir=""
  local extracted_root=""

  [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || error "Unsafe managed Node version: $version"
  [ ! -L "$target_dir" ] || error "Managed Node target cannot be a symlink: $target_dir"
  if [ -x "$target_dir/bin/node" ] && [ "${CODEX_MANAGED_NODE_REFRESH:-0}" != "1" ]; then
    printf 'Using existing managed Node: %s\n' "$target_dir/bin/node"
    return 0
  fi

  mkdir -p "$cache_dir"
  if [ ! -s "$archive_path" ]; then
    curl -fsSL --connect-timeout 30 --max-time 900 "$(archive_url "$version" "$arch")" -o "$archive_path"
  fi
  if [ ! -s "$manifest_path" ]; then
    curl -fsSL --connect-timeout 30 --max-time 60 "$(manifest_url "$version")" -o "$manifest_path"
  fi

  expected_hash="$(awk -v file="$archive" '$2 == file || $2 == "*" file { print $1; exit }' "$manifest_path")"
  [ -n "$expected_hash" ] || error "Managed Node checksum is missing for $archive"
  actual_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
  [ "$actual_hash" = "$expected_hash" ] \
    || error "Managed Node checksum mismatch for $archive"

  extract_dir="$(mktemp -d "$cache_dir/.managed-node-extract.XXXXXX")"
  trap 'rm -rf "$extract_dir"' RETURN
  tar -xJf "$archive_path" -C "$extract_dir"
  extracted_root="$extract_dir/node-v${version}-linux-${arch}"
  [ -d "$extracted_root/bin" ] || error "Managed Node archive has an unexpected layout: $archive"

  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -a "$extracted_root/." "$target_dir/"
  chmod 0755 "$target_dir/bin/node"
  trap - RETURN
  rm -rf "$extract_dir"
  printf 'Installed managed Node %s (%s) at %s\n' "$version" "$arch" "$target_dir"
}

main() {
  case "${1:-}" in
    print-url)
      [ "$#" -eq 3 ] || { usage >&2; exit 2; }
      node_arch "$3" >/dev/null
      archive_url "$2" "$(node_arch "$3")"
      ;;
    install)
      [ "$#" -ge 3 ] && [ "$#" -le 5 ] || { usage >&2; exit 2; }
      install_managed_node "$2" "$3" "${4:-$DEFAULT_VERSION}" "${5:-$(uname -m)}"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
