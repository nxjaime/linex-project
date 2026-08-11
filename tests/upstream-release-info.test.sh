#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

ARCHIVE="$TEMP_DIR/Codex.zip"
APPCAST="$TEMP_DIR/appcast.xml"
printf 'linex-upstream-fixture\n' > "$ARCHIVE"
ARCHIVE_URL="file://$ARCHIVE"
printf '%s\n' \
  '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' \
  '<item><sparkle:shortVersionString>26.900.10000</sparkle:shortVersionString><sparkle:version>7000</sparkle:version><enclosure url="'"$ARCHIVE_URL"'" length="23" /></item>' \
  '</channel></rss>' > "$APPCAST"

output="$(python3 "$PROJECT_DIR/scripts/upstream-release-info.py" \
  --appcast "$APPCAST" --archive "$ARCHIVE")"

python3 - "$output" "$ARCHIVE" <<'PY'
import hashlib
import json
import pathlib
import sys

report = json.loads(sys.argv[1])
archive = pathlib.Path(sys.argv[2])
assert report["version"] == "26.900.10000"
assert report["build"] == "7000"
assert report["archive_url"].startswith("file://")
assert report["archive_size"] == archive.stat().st_size
assert report["archive_sha256"] == hashlib.sha256(archive.read_bytes()).hexdigest()
assert report["content_length"] == str(archive.stat().st_size)
PY

direct_output="$(python3 "$PROJECT_DIR/scripts/upstream-release-info.py" \
  --archive-url "https://example.invalid/Codex.zip" \
  --version 26.900.10000 --build 7000 --archive "$ARCHIVE")"
python3 - "$direct_output" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["archive_url"] == "https://example.invalid/Codex.zip"
assert report["archive_sha256"]
assert report["identity"]
PY

printf 'Upstream release metadata tests passed.\n'
