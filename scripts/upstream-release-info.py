#!/usr/bin/env python3
"""Read an official Codex appcast item and optionally fingerprint its archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def read_source(source: str) -> bytes:
    if source.startswith(("http://", "https://", "file://")):
        request = urllib.request.Request(source, headers={"User-Agent": "Linex/1.0"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    return pathlib.Path(source).read_bytes()


def http_identity(url: str) -> dict[str, str | None]:
    result: dict[str, str | None] = {
        "etag": None,
        "last_modified": None,
        "content_length": None,
    }
    if not url.startswith(("http://", "https://")):
        return result

    request = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "Linex/1.0 (+https://github.com/nxjaime/linex-project)"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result["etag"] = response.headers.get("ETag")
            result["last_modified"] = response.headers.get("Last-Modified")
            result["content_length"] = response.headers.get("Content-Length")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        # A CDN may reject HEAD even though the archive is downloadable. The
        # appcast metadata and any locally computed hash remain useful.
        pass
    return result


def select_item(appcast: bytes, requested_version: str | None) -> dict[str, str]:
    root = ET.fromstring(appcast)
    items = root.findall("./channel/item")
    if not items:
        raise ValueError("Appcast contains no release items")

    selected = None
    for item in items:
        version = (item.findtext(SPARKLE + "shortVersionString") or "").strip()
        if not requested_version or version == requested_version:
            selected = item
            break
    if selected is None:
        raise ValueError(f"Unknown appcast version: {requested_version}")

    version = (selected.findtext(SPARKLE + "shortVersionString") or "").strip()
    build = (selected.findtext(SPARKLE + "version") or "").strip()
    enclosure = selected.find("enclosure")
    archive_url = enclosure.get("url", "").strip() if enclosure is not None else ""
    if not version or not build or not archive_url:
        raise ValueError("Appcast item is missing version, build, or enclosure URL")
    return {"version": version, "build": build, "archive_url": archive_url}


def fingerprint_archive(archive: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with pathlib.Path(archive).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", help="Appcast URL or local XML path")
    parser.add_argument("--archive-url", help="Direct archive URL when no appcast is available")
    parser.add_argument("--build", help="Build number for a direct archive")
    parser.add_argument("--version", help="Select a specific appcast version")
    parser.add_argument("--archive", help="Local archive to hash")
    parser.add_argument("--head", action="store_true", help="Read archive HTTP identity headers")
    args = parser.parse_args()

    if args.appcast:
        item = select_item(read_source(args.appcast), args.version)
    else:
        if not args.archive_url or not args.version or not args.build:
            parser.error("--appcast or (--archive-url, --version, and --build) is required")
        item = {
            "version": args.version,
            "build": args.build,
            "archive_url": args.archive_url,
        }
    report: dict[str, object] = {
        **item,
        "etag": None,
        "last_modified": None,
        "content_length": None,
        "archive_sha256": None,
        "archive_size": None,
    }
    if args.head:
        report.update(http_identity(item["archive_url"]))
    if args.archive:
        archive_sha256, archive_size = fingerprint_archive(args.archive)
        report["archive_sha256"] = archive_sha256
        report["archive_size"] = archive_size
        if report["content_length"] is None:
            report["content_length"] = str(archive_size)
    identity_parts = [
        str(report["version"]),
        str(report["build"]),
        str(report["archive_sha256"] or ""),
        str(report["etag"] or ""),
        str(report["last_modified"] or ""),
        str(report["content_length"] or ""),
        str(report["archive_url"]),
    ]
    report["identity"] = hashlib.sha256("\n".join(identity_parts).encode()).hexdigest()
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
