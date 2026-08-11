#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_DIR/.github/workflows/check-release.yml"

grep -Fq 'scripts/upstream-release-info.py' "$WORKFLOW"
grep -Fq -- '--head' "$WORKFLOW"
grep -Fq 'identity' "$WORKFLOW"
grep -Fq 'LATEST_IDENTITY' "$WORKFLOW"
grep -Fq 'steps.baseline.outputs.identity' "$WORKFLOW"
grep -Fq 'upstream-fingerprint:' "$WORKFLOW"

if grep -Eq 'linex-release\.sh (promote|approve)|dpkg(-deb)? -i|apt(-get)? install' "$WORKFLOW"; then
  echo 'The scheduled workflow must not install or promote releases.' >&2
  exit 1
fi

echo 'Release workflow fingerprint tests passed.'
